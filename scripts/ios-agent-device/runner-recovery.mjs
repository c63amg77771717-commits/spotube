// Retry only a runner refusal that explicitly proves no device action was dispatched.
// Never repeat an uncertain or completed toggle, player action, or application failure.
export async function retryUndispatchedRunnerBusy(action, sleep, record = () => {}) {
  const delays = [3000, 8000];
  for (let attempt = 1; ; attempt++) {
    try { return await action(attempt); }
    catch (error) {
      const details = error.details;
      const busy = details?.reason === 'runner_busy' && details?.dispatched === 'no' &&
        details?.runnerErrorCode === 'RUNNER_BUSY';
      if (!busy || attempt > delays.length) throw error;
      record({ attempt, delayMs: delays[attempt - 1], reason: details.reason,
        dispatched: details.dispatched, message: error.message });
      await sleep(delays[attempt - 1]);
    }
  }
}
