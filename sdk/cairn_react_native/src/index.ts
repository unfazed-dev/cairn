// @cairn/react-native — public entrypoint.
//
// Re-exports the TS facade and the TurboModule spec type. The default
// NativeCairn module instance is intentionally NOT re-exported — apps drive
// the facade; direct native-module access is for advanced / debugging paths.

export { CairnClient } from "./CairnClient";
export type {
  CairnClientConfig,
  Row,
  Subscription,
  WriteOp,
} from "./CairnClient";
export type { Spec as NativeCairnSpec } from "./NativeCairn";
