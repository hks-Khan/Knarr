import { describe, expect, it } from 'vitest';
import { groupProgress } from './progressGroups';
const row = (id: string, kind: string, extra = {}) => ({ id, kind, text: id, ...extra });
const activity = (id: string, state = 'completed', start = 1000, end = 3000) => row(id, 'activity', {
  activity: { kind: 'tool', title: '파일 읽기', state, label: '완료', startedAt: start, updatedAt: end },
});
function project(items: any[], responding = false) {
  return groupProgress(items.map(x => x.id), Object.fromEntries(items.map(x => [x.id, x])), responding);
}
describe('response progress groups', () => {
  it('keeps the final answer visible and folds intermediate prose with all activities', () => {
    const p = project([row('u','user'), row('intro','assistant'), activity('a'), row('update','assistant'), activity('b'), row('answer','assistant')]);
    expect(p.order).toEqual(['u','a','answer']);
    expect(p.groups.a.ids).toEqual(['intro','a','update','b']);
    expect(p.owner.update).toBe('a');
    expect(p.groups.a.startedAt).toBe(1000);
    expect(p.groups.a.endedAt).toBe(3000);
  });
  it('separates user turns and does not absorb approvals or questions', () => {
    const p = project([row('u1','user'), activity('a'), row('q','question'), row('u2','user'), activity('b','running')], true);
    expect(p.order).toEqual(['u1','a','q','u2','b']);
    expect(p.groups.a.running).toBe(false);
    expect(p.groups.b.running).toBe(true);
  });
  it('does not hide interactive assistant content or ordinary answers', () => {
    expect(project([row('a','assistant')]).order).toEqual(['a']);
    const p = project([row('interactive','assistant',{text:'```openui\nroot = Button("확인")\n```'}), activity('a')]);
    expect(p.order).toEqual(['interactive','a']);
  });
  it('uses wall time for concurrent tools and preserves failures in the summary', () => {
    const p = project([activity('a','failed',1000,6000), activity('b','completed',2000,5000)]);
    expect(p.groups.a.endedAt - p.groups.a.startedAt).toBe(5000);
    expect(p.groups.a.label).toBe('실패 기록 있음');
  });
  it('does not mark old records active while a new request waits for its first event', () => {
    const p = project([activity('a'), row('u','user')], true);
    expect(p.groups.a.running).toBe(false);
  });
  it('uses a stable activity ID as records arrive and exposes all parallel work', () => {
    const p = project([activity('a','running'), activity('b','running')], true);
    expect(p.order).toEqual(['a']);
    expect(p.groups.a.title).toBe('파일 읽기 외 1개');
    expect(project([activity('a'), activity('b'), row('answer','assistant')]).order).toEqual(['a','answer']);
  });
  it('keeps previous conversation records idle during another response', () => {
    const a = activity('a');
    const p = groupProgress(['a'], {a}, true, 10000);
    expect(p.groups.a.running).toBe(false);
  });
  it('folds intermediate prose after tools while retaining the final answer', () => {
    const p = project([activity('a'), row('update','assistant'), row('answer','assistant')]);
    expect(p.order).toEqual(['a','answer']);
    expect(p.groups.a.ids).toEqual(['a','update']);
  });

});
