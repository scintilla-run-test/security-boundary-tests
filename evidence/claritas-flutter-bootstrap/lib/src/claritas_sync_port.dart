/// Monotonic visualization revision observed by a Claritas client.
final class ClaritasRevision implements Comparable<ClaritasRevision> {
  const ClaritasRevision(this.value) : assert(value >= 0);

  final int value;

  @override
  int compareTo(ClaritasRevision other) {
    return value.compareTo(other.value);
  }

  @override
  bool operator ==(Object other) {
    return other is ClaritasRevision && other.value == value;
  }

  @override
  int get hashCode {
    return value.hashCode;
  }

  @override
  String toString() {
    return 'ClaritasRevision($value)';
  }
}

/// Transport-neutral boundary implemented by whichever sync runtime is selected.
///
/// This package deliberately does not own persistence, networking, or conflict
/// resolution. Those semantics remain in the Claritas sync/runtime layer.
abstract interface class ClaritasSyncPort {
  Future<ClaritasRevision> latestRevision();

  Stream<ClaritasRevision> watchRevisions();
}
