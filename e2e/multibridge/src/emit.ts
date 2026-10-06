/** Machine-readable line for shell orchestration (`grep E2E_RESULT=`). */
export function emitResult(tag: string, payload: Record<string, unknown>): void {
  console.log(`${tag}=${JSON.stringify(payload)}`)
}
