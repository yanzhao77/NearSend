package com.nearsend.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * The Android file-access channel: SAF document picking, bounded-memory reads, and SAF writes.
 *
 * ## Why a channel exists at all
 *
 * `AGENTS.md` §9: "Android SAF URI、iOS 安全作用域资源和 Windows 存储句柄通过平台存储适配层处理，
 * **不得假设它们都是普通磁盘路径**". A `content://` URI is not a path, so `dart:io` cannot open it,
 * and both directions of a transfer need the user's own files: a sender reads what they picked, and
 * a receiver writes where they chose.
 *
 * ## The rule this must not break
 *
 * `AGENTS.md` §2 rule 4 forbids reading a whole file into memory, and the obvious SAF shortcut does
 * exactly that: `contentResolver.openInputStream(uri).readBytes()` returns the entire file. So every
 * read here is **one bounded chunk at a time**, addressed by an offset, with the stream obtained
 * fresh from the provider rather than held open for the whole transfer. The Dart side asks for one
 * protocol chunk, writes it, asks for the next, and awaits the peer before the one after that - so
 * at most one chunk exists in this process at any moment.
 *
 * Seeking uses `FileChannel.position` when the provider hands out a real file descriptor and falls
 * back to `InputStream.skip` otherwise. That fallback is O(offset) in the worst case, and it is a
 * cost rather than a hidden one: the alternative is buffering the file, which is the thing this
 * class exists to avoid. A provider that seeks slowly shows up as a slow transfer, not a wrong one.
 *
 * ## What it deliberately does not do
 *
 * It does not persist a URI permission for later use. A transfer that outlives the process needs
 * `takePersistableUriPermission`, and `AGENTS.md` §9 wants that behaviour verified on a device before
 * anything relies on it; when the permission is gone, `readChunk` fails and the Dart side must enter
 * BLOCKED rather than silently recreating a duplicate file. Persisting it without that verification
 * would be the silent version of the same failure.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.nearsend.app/files"

    /** The single in-flight pick, so a second request cannot race the first. */
    private var pendingPick: MethodChannel.Result? = null
    private val pickRequestCode = 4711

    /** Open write channels, keyed by URI, so a chunked write does not reopen per chunk. */
    private val writeChannels = HashMap<String, FileChannel>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pickFiles" -> pickFiles(result)
                "probe" -> result.success(probe(uriOf(call)))
                "readChunk" -> result.success(
                    readChunk(
                        uri = uriOf(call),
                        offset = (call.argument<Number>("offset") ?: 0).toLong(),
                        length = (call.argument<Number>("length") ?: 0).toInt(),
                    ),
                )
                "beginWrite" -> result.success(beginWrite(call))
                "writeChunk" -> result.success(writeChunk(call))
                "endWrite" -> result.success(endWrite(call, force = true))
                "abortWrite" -> result.success(endWrite(call, force = false))
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            // Only the exception's class and message: a URI can carry a document id, and
            // AGENTS.md §5 keeps user file locations out of diagnostics. The Dart side receives a
            // failure, never a path.
            result.error(
                "NS-SAF",
                error.javaClass.simpleName + ": " + error.message,
                null,
            )
        }
    }

    private fun uriOf(call: MethodCall): Uri {
        val value = call.argument<String>("uri")
            ?: throw IllegalArgumentException("a uri argument is required")
        return Uri.parse(value)
    }

    // --- picking ------------------------------------------------------------------------------

    private fun pickFiles(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("NS-SAF", "a pick is already in progress", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(intent, pickRequestCode)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRequestCode) {
            return
        }
        val pending = pendingPick ?: return
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            // An empty list rather than an error: the user cancelling is not a failure.
            pending.success(emptyList<Map<String, Any?>>())
            return
        }
        val picked = ArrayList<Map<String, Any?>>()
        data.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                picked.add(probe(clip.getItemAt(index).uri))
            }
        }
        data.data?.let { picked.add(probe(it)) }
        pending.success(picked)
    }

    // --- reading ------------------------------------------------------------------------------

    /** What the Dart side needs to build a manifest entry, and nothing else. */
    private fun probe(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size = -1L
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    name = cursor.getString(nameIndex)
                }
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    size = cursor.getLong(sizeIndex)
                }
            }
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: uri.lastPathSegment ?: "unknown"),
            // -1 means the provider would not say, which the Dart side must treat as unknown
            // rather than as an empty file.
            "sizeBytes" to size,
        )
    }

    /**
     * Reads at most [length] bytes at [offset].
     *
     * At most one buffer of [length] exists here, and [length] is one protocol chunk, so the memory
     * this can occupy is bounded by a value the Dart side chooses and the protocol fixes.
     */
    private fun readChunk(uri: Uri, offset: Long, length: Int): ByteArray {
        if (length <= 0) {
            return ByteArray(0)
        }
        contentResolver.openInputStream(uri).use { stream ->
            if (stream == null) {
                throw IllegalStateException("the provider opened no stream")
            }
            if (stream is FileInputStream) {
                // A real descriptor, so the offset costs nothing to reach.
                stream.channel.position(offset)
            } else {
                var remaining = offset
                while (remaining > 0) {
                    val skipped = stream.skip(remaining)
                    if (skipped <= 0) {
                        // The provider cannot seek and the stream ended first: a short read rather
                        // than padding, because padding would look like data.
                        return ByteArray(0)
                    }
                    remaining -= skipped
                }
            }
            val buffer = ByteArray(length)
            var filled = 0
            while (filled < length) {
                val read = stream.read(buffer, filled, length - filled)
                if (read <= 0) {
                    break
                }
                filled += read
            }
            return if (filled == length) buffer else buffer.copyOf(filled)
        }
    }

    // --- writing ------------------------------------------------------------------------------

    private fun beginWrite(call: MethodCall): Boolean {
        val uri = uriOf(call)
        val mode = call.argument<String>("mode") ?: "rwt"
        val descriptor = contentResolver.openFileDescriptor(uri, mode)
            ?: throw IllegalStateException("the provider opened no descriptor for writing")
        writeChannels[uri.toString()] =
            FileOutputStream(descriptor.fileDescriptor).channel
        return true
    }

    private fun writeChunk(call: MethodCall): Int {
        val uri = uriOf(call)
        val channel = writeChannels[uri.toString()]
            ?: throw IllegalStateException("no write is open for this document")
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("a bytes argument is required")
        val offset = (call.argument<Number>("offset") ?: 0).toLong()
        channel.position(offset)
        channel.write(ByteBuffer.wrap(bytes))
        return bytes.size
    }

    /**
     * Ends a write.
     *
     * §8 wants bytes durable before a chunk row is committed, so a commit forces the channel before
     * answering. What the platform actually guarantees is the device's business and is B04's
     * question; what this does is ask, and then report what it was told.
     */
    private fun endWrite(call: MethodCall, force: Boolean): Boolean {
        val uri = uriOf(call)
        val channel = writeChannels.remove(uri.toString()) ?: return true
        try {
            if (force) {
                channel.force(true)
            }
        } finally {
            channel.close()
        }
        return true
    }
}
