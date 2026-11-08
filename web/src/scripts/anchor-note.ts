import { pageTimer } from './page';

export function anchorNote(note: Pick<HTMLElement, 'textContent'>, id: string, signal: AbortSignal) {
  const empty = pageTimer(signal);
  return async (write: () => Promise<void>): Promise<void> => {
    try {
      await write();
      note.textContent = `#${id} · link copied`;
    } catch {
      note.textContent = `#${id}`;
    }
    empty.set(() => (note.textContent = ''), 2400);
  };
}
