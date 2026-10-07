import 'package:dev_tools_light/src/vm/vm_api.dart';
import 'package:vm_service/vm_service.dart' as vms;

/// Why a retaining path could not be fetched.
enum RetainingPathFailure {
  /// The object was collected in the meantime (not a leak).
  collected,

  /// The temporary object id expired; obtain a new one and retry.
  expired,

  /// The RPC failed.
  rpcError,
}

/// Outcome of [RetainingPathClient.fetch].
class RetainingPathResult {
  RetainingPathResult._(this.path, this.failure, this.message);

  /// A successful result.
  RetainingPathResult.ok(vms.RetainingPath path) : this._(path, null, null);

  /// A failed result.
  RetainingPathResult.failed(RetainingPathFailure failure, [String? message])
    : this._(null, failure, message);

  /// The path, when [failure] is null.
  final vms.RetainingPath? path;

  /// The failure, when [path] is null.
  final RetainingPathFailure? failure;

  /// Detail for [failure].
  final String? message;
}

/// Fetches retaining paths and maps VM errors to [RetainingPathFailure].
class RetainingPathClient {
  /// Creates a client.
  const RetainingPathClient();

  /// Fetches the retaining path of [objectId].
  ///
  /// An object the VM can still resolve but finds no retainers for (it is
  /// unreachable and merely not collected yet) is reported as
  /// [RetainingPathFailure.collected]: for a leak detector the two are the
  /// same thing.
  Future<RetainingPathResult> fetch(
    VmApi api, {
    required String isolateId,
    required String objectId,
    required int limit,
  }) async {
    try {
      final path = await api.getRetainingPath(isolateId, objectId, limit);
      if (path.elements?.isEmpty ?? true) {
        return RetainingPathResult.failed(
          RetainingPathFailure.collected,
          'no retainers',
        );
      }
      return RetainingPathResult.ok(path);
    } on vms.SentinelException catch (error) {
      final kind = error.sentinel.kind;
      if (kind == vms.SentinelKind.kCollected) {
        return RetainingPathResult.failed(RetainingPathFailure.collected);
      }
      return RetainingPathResult.failed(RetainingPathFailure.expired, kind);
    } on vms.RPCError catch (error) {
      return RetainingPathResult.failed(
        RetainingPathFailure.rpcError,
        '${error.code}: ${error.message}',
      );
    } on Object catch (error) {
      return RetainingPathResult.failed(
        RetainingPathFailure.rpcError,
        '$error',
      );
    }
  }
}
