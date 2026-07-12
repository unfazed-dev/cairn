// Type declarations for @cairn/web — reduced-scope feasibility proof.
// See index.js header for the ceiling / upgrade-path notes.

export interface CairnClientConfig {
  url?: string | null;
  token?: string | null;
  table?: string | null;
}

export interface WriteResult {
  /** Durable LSN after the write (resume_lsn on reconnect). */
  checkpoint: number;
  /** Rows committed by this write. */
  rowsApplied: number;
}

export interface Row {
  pk: string;
  payload: Buffer;
}

/**
 * PowerSync-style sync client. Reduced-scope: no live WS transport in
 * node — drives the apply engine only.
 */
export declare class CairnClient {
  constructor(config?: CairnClientConfig);
  connect(): Promise<CairnClient>;
  subscribe(table: string, whereSql?: string | null): CairnClient;
  write(table: string, pk: string | number, payload: Uint8Array | number[]): WriteResult;
  query(table: string): Row[];
  watch(table: string, callback: (rows: Row[]) => void): () => void;
  readonly checkpoint: number;
  readonly rowCount: number;
}
