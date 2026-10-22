/** Derived once per incoming snapshot; stored transcript rows remain unchanged. */
type ProgressRow = {
  kind: string;
  text: string;
  activity?: { title: string; state: string; startedAt: number; updatedAt: number };
};
export type ProgressGroup = {
  id: string;
  ids: string[];
  title: string;
  label: string;
  running: boolean;
  startedAt: number;
  endedAt: number;
};
export type ProgressProjection = {
  order: string[];
  groups: Record<string, ProgressGroup>;
  owner: Record<string, string>;
};
export function groupProgress(order: string[], rows: Record<string, ProgressRow>, responding: boolean, responseStartedAt?: number | null, withoutResponseStart = false): ProgressProjection {
  const result: ProgressProjection = { order: [], groups: {}, owner: {} };
  let turn: string[] = [];
  const flush = (active: boolean) => {
    const activities = turn.filter(id => rows[id]?.activity);
    if (!activities.length) { result.order.push(...turn); turn = []; return; }
    const lastActivity = turn.lastIndexOf(activities.at(-1)!);
    const lastAssistant = turn.reduce((last, id, index) => rows[id]?.kind === 'assistant' ? index : last, -1);
    const progressEnd = Math.max(lastActivity, lastAssistant);
    const ids = turn.filter((id, i) => rows[id]?.activity ||
      (i < progressEnd && rows[id]?.kind === 'assistant' && !rows[id].text.includes('```openui')));
    const id = activities[0];
    const events = activities.map(id => rows[id].activity!);
    const live = events.filter(a => a.state === 'running');
    // The Mac sends when the reply started. The phone's payload has none, so `withoutResponseStart`
    // marks a group live only while one of its own records still runs.
    const running = active && responding && (withoutResponseStart ? live.length > 0
      : responseStartedAt == null || events.some(a => a.updatedAt >= responseStartedAt));
    const label = running ? '진행 중' : events.some(a => a.state === 'failed') ? '실패 기록 있음'
      : events.some(a => a.state === 'stopped') ? '중지됨'
      : events.some(a => ['interrupted', 'running'].includes(a.state)) ? '결과 미수신' : '완료';
    const title = running && live.length ? live.at(-1)!.title + (live.length > 1 ? ` 외 ${live.length - 1}개` : '') : '진행 기록';
    result.groups[id] = { id, ids, title, label, running,
      startedAt: Math.min(...events.map(a => a.startedAt)), endedAt: Math.max(...events.map(a => a.updatedAt)) };
    for (const entry of ids) result.owner[entry] = id;
    let inserted = false;
    for (const entry of turn) {
      if (!result.owner[entry]) result.order.push(entry);
      else if (!inserted) { result.order.push(id); inserted = true; }
    }
    turn = [];
  };
  for (const id of order) {
    if (rows[id]?.kind === 'user' || rows[id]?.kind === 'day') { flush(false); result.order.push(id); }
    else turn.push(id);
  }
  flush(true);
  return result;
}
