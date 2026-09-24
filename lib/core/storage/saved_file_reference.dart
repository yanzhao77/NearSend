class SavedFileReference {
  const SavedFileReference({required this.displayName, this.targetRef});

  final String displayName;
  final String? targetRef;

  @override
  String toString() => 'SavedFileReference(hasTarget=${targetRef != null})';
}
