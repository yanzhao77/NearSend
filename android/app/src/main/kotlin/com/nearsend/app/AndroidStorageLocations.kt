package com.nearsend.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Owns Android receive-directory grants and documents created under those grants. */
class AndroidStorageLocations(private val activity: Activity) {
    private var pendingDirectoryPick: MethodChannel.Result? = null
    private val uncommittedDocuments = HashSet<String>()

    fun defaultReceiveLocation(): Map<String, Any?> {
        val directory = java.io.File(activity.applicationContext.filesDir, "received")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("the default receive directory could not be created")
        }
        return locationResult(
            kind = "appPrivate",
            opaqueValue = directory.absolutePath,
            displayName = "应用私有存储",
            permissionState = "granted",
        )
    }

    fun measureFreeSpace(locationRef: String?): Map<String, Any?> {
        if (locationRef.isNullOrBlank() || locationRef.startsWith("content://")) {
            return mapOf(
                "volume" to "unknown",
                "label" to "保存位置",
                "freeBytes" to null,
            )
        }
        return try {
            val stat = StatFs(locationRef)
            mapOf(
                "volume" to "android-app-private",
                "label" to "应用私有存储",
                "freeBytes" to stat.availableBytes,
            )
        } catch (_: Exception) {
            mapOf(
                "volume" to "unknown",
                "label" to "保存位置",
                "freeBytes" to null,
            )
        }
    }

    @Suppress("DEPRECATION")
    fun pickReceiveDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryPick != null) {
            result.error("NS-SAF", "a directory pick is already in progress", null)
            return
        }
        pendingDirectoryPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, directoryPickRequestCode)
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != directoryPickRequestCode) return false
        val pending = pendingDirectoryPick ?: return true
        pendingDirectoryPick = null
        val treeUri = data?.data
        if (resultCode != Activity.RESULT_OK || treeUri == null) {
            pending.success(null)
            return true
        }
        val grantFlags = data.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        if (grantFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0 ||
            grantFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0
        ) {
            pending.error("NS-SAF-PERMISSION", "the selected tree is not writable", null)
            return true
        }
        activity.contentResolver.takePersistableUriPermission(treeUri, grantFlags)
        pending.success(validateReceiveDirectory(treeUri))
        return true
    }

    fun validateReceiveDirectory(treeUri: Uri): Map<String, Any?> {
        val permission = activity.contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == treeUri
        }
        val granted = permission?.isReadPermission == true && permission.isWritePermission
        if (!granted) {
            return locationResult(
                kind = "androidDocumentTree",
                opaqueValue = treeUri.toString(),
                displayName = treeDisplayName(treeUri),
                permissionState = "denied",
            )
        }
        val readable = try {
            activity.contentResolver.query(
                treeDocumentUri(treeUri),
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { it.moveToFirst() } == true
        } catch (_: Exception) {
            false
        }
        return locationResult(
            kind = "androidDocumentTree",
            opaqueValue = treeUri.toString(),
            displayName = treeDisplayName(treeUri),
            permissionState = if (readable) "granted" else "unavailable",
        )
    }

    fun listDirectory(treeUri: Uri): List<Map<String, Any?>> {
        requireGranted(treeUri)
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, rootId)
        val entries = ArrayList<Map<String, Any?>>()
        activity.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                entries.add(
                    mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(
                            treeUri,
                            cursor.getString(0),
                        ).toString(),
                        "name" to cursor.getString(1),
                        "sizeBytes" to if (cursor.isNull(2)) -1L else cursor.getLong(2),
                        "isDirectory" to (
                            cursor.getString(3) == DocumentsContract.Document.MIME_TYPE_DIR
                        ),
                    ),
                )
            }
        } ?: throw IllegalStateException("the provider did not return a directory listing")
        return entries
    }

    fun createDocument(treeUri: Uri, displayName: String): Map<String, Any?> {
        requireGranted(treeUri)
        if (displayName.isBlank() || displayName.contains('/') || displayName.contains('\\')) {
            throw IllegalArgumentException("the display name must be one plain file name")
        }
        val created = DocumentsContract.createDocument(
            activity.contentResolver,
            treeDocumentUri(treeUri),
            "application/octet-stream",
            displayName,
        ) ?: throw IllegalStateException("the provider did not create a document")
        uncommittedDocuments.add(created.toString())
        return probe(created)
    }

    fun completeDocument(uri: Uri, committed: Boolean) {
        if (committed) {
            uncommittedDocuments.remove(uri.toString())
        } else if (uncommittedDocuments.remove(uri.toString())) {
            DocumentsContract.deleteDocument(activity.contentResolver, uri)
        }
    }

    fun openSavedFile(targetRef: String): Map<String, String> {
        val uri = readableTargetUri(targetRef) ?: return actionResult("unavailable")
        return try {
            activity.contentResolver.openAssetFileDescriptor(uri, "r")?.use { }
                ?: return actionResult("unavailable")
            val type = activity.contentResolver.getType(uri) ?: "application/octet-stream"
            activity.startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, type)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
            actionResult("completed")
        } catch (_: SecurityException) {
            actionResult("permissionDenied")
        } catch (_: ActivityNotFoundException) {
            actionResult("unsupported")
        } catch (_: Exception) {
            actionResult("failed")
        }
    }

    fun revealSavedFile(targetRef: String): Map<String, String> {
        val documentUri = Uri.parse(targetRef)
        if (documentUri.scheme != "content" || !DocumentsContract.isDocumentUri(activity, documentUri)) {
            return actionResult("unsupported")
        }
        return try {
            val treeUri = DocumentsContract.buildTreeDocumentUri(
                documentUri.authority ?: return actionResult("unavailable"),
                DocumentsContract.getTreeDocumentId(documentUri),
            )
            activity.startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(treeUri, DocumentsContract.Document.MIME_TYPE_DIR)
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                },
            )
            actionResult("completed")
        } catch (_: SecurityException) {
            actionResult("permissionDenied")
        } catch (_: ActivityNotFoundException) {
            actionResult("unsupported")
        } catch (_: Exception) {
            actionResult("failed")
        }
    }

    private fun readableTargetUri(targetRef: String): Uri? {
        val parsed = Uri.parse(targetRef)
        if (parsed.scheme == "content") return parsed
        if (parsed.scheme != null || targetRef.isBlank()) return null
        return try {
            val root = File(activity.filesDir, "received").canonicalFile
            val target = File(targetRef).canonicalFile
            if (!target.isFile || !target.path.startsWith(root.path + File.separator)) return null
            FileProvider.getUriForFile(
                activity,
                activity.packageName + ".fileprovider",
                target,
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun actionResult(status: String): Map<String, String> =
        mapOf("status" to status)

    private fun requireGranted(treeUri: Uri) {
        if (validateReceiveDirectory(treeUri)["permissionState"] != "granted") {
            throw SecurityException("the persisted directory permission is unavailable")
        }
    }

    private fun treeDisplayName(treeUri: Uri): String = try {
        activity.contentResolver.query(
            treeDocumentUri(treeUri),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
        } ?: "已选择的目录"
    } catch (_: Exception) {
        "已选择的目录"
    }

    private fun treeDocumentUri(treeUri: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )

    private fun probe(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size = -1L
        activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) name = cursor.getString(nameIndex)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) size = cursor.getLong(sizeIndex)
            }
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to (name ?: uri.lastPathSegment ?: "unknown"),
            "sizeBytes" to size,
        )
    }

    private fun locationResult(
        kind: String,
        opaqueValue: String,
        displayName: String,
        permissionState: String,
    ): Map<String, Any?> = mapOf(
        "kind" to kind,
        "opaqueValue" to opaqueValue,
        "displayName" to displayName,
        "permissionState" to permissionState,
    )

    private companion object {
        const val directoryPickRequestCode = 4712
    }
}
