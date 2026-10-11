/**
 * The visible half of setting mail aside: what the Gmail lane did NOT import,
 * grouped by sender, with a per-sender "This is my bank" that imports it.
 *
 * # Why this component has to exist
 *
 * `v2/mailbox/fetch.ts` authors an op only for mail plausibly from a bank,
 * because an op is permanent and a newsletter's empty review card would be
 * permanent with it. That filtering is only honest if the user can see what it
 * held back and overrule it — otherwise it is a silent drop with extra steps.
 * So this surface says three true things and offers one action:
 *
 *   - these were not imported, and nothing was written to the ledger for them;
 *   - they are still in the mailbox, exactly as they arrived (D5 — the burner
 *     mailbox is the durable archive, which is what makes this reversible);
 *   - if one is your bank, say so and ledger reads them now and in future.
 *
 * # Motion
 *
 * None of its own. It renders inside the settings drill-in's `SettingsPage` (or
 * the onboarding catch-up summary), both of which own their transitions. No
 * `m.*`, no per-component reduced-motion handling.
 */

import { useCallback, useState } from "react";

import { Button } from "../../components/ui/Button";
import { SectionLabel } from "../../components/ui/SectionLabel";
import type { CycleReport } from "../../v2/mailbox/fetch";
import { SET_ASIDE_COPY, setAsideGroups, type SetAsideGroup } from "../../v2/mailbox/setAside";
import type { SetAsideLog } from "../../v2/mailbox/state";

export interface SetAsideSectionProps {
  /** The device-local log (`readMailboxSetAside`). */
  log: SetAsideLog;
  /**
   * Trusts the domain and imports its set-aside messages — the runtime's
   * `importMailboxSetAsideDomain`. Resolves with what the import did; rejects
   * only on a failure the user should be told about.
   */
  importDomain: (domain: string) => Promise<CycleReport>;
  /** Called after a successful import, so the parent can re-read the log. */
  onImported?: (domain: string, report: CycleReport) => void;
}

export function SetAsideSection({ log, importDomain, onImported }: SetAsideSectionProps) {
  // Nothing set aside is not news — the surface appears only when it has
  // something to say.
  if (log.count === 0) return null;
  const groups = setAsideGroups(log);
  return (
    <div data-testid="mailbox-set-aside" className="space-y-3">
      <SectionLabel>{SET_ASIDE_COPY.title}</SectionLabel>
      <p className="text-xs leading-relaxed text-muted">{SET_ASIDE_COPY.body}</p>
      <p className="text-xs leading-relaxed text-muted">{SET_ASIDE_COPY.trustHint}</p>
      <ul className="flex flex-col gap-3">
        {groups.map((group) => (
          <SetAsideGroupRow
            key={group.domain === "" ? "__unknown" : group.domain}
            group={group}
            importDomain={importDomain}
            onImported={onImported}
          />
        ))}
      </ul>
      {log.dropped > 0 && (
        <p data-testid="mailbox-set-aside-dropped" className="text-xs leading-relaxed text-muted">
          {SET_ASIDE_COPY.dropped(log.dropped)}
        </p>
      )}
    </div>
  );
}

type RowState =
  | { status: "idle" }
  | { status: "working" }
  | { status: "done"; report: CycleReport }
  | { status: "failed" };

function SetAsideGroupRow({
  group,
  importDomain,
  onImported,
}: {
  group: SetAsideGroup;
  importDomain: (domain: string) => Promise<CycleReport>;
  onImported?: (domain: string, report: CycleReport) => void;
}) {
  const [state, setState] = useState<RowState>({ status: "idle" });

  const run = useCallback(async () => {
    setState({ status: "working" });
    try {
      const report = await importDomain(group.domain);
      // A halted import imported nothing it could not push; say so rather than
      // reporting a cheerful count the ledger does not have.
      if (report.haltedOn !== undefined) {
        setState({ status: "failed" });
        return;
      }
      setState({ status: "done", report });
      onImported?.(group.domain, report);
    } catch {
      setState({ status: "failed" });
    }
  }, [group.domain, importDomain, onImported]);

  return (
    <li
      data-testid={`mailbox-set-aside-group-${group.domain === "" ? "unknown" : group.domain}`}
      className="rounded-[var(--radius)] border border-border p-3 space-y-2"
    >
      <div className="space-y-1">
        <p className="text-sm font-medium text-fg break-words">
          {group.domain === "" ? SET_ASIDE_COPY.unknownDomain : group.domain}
        </p>
        <p className="text-xs text-muted">
          {group.count} {group.count === 1 ? "message" : "messages"}
        </p>
        {group.subjects.length > 0 && (
          <ul className="text-xs leading-relaxed text-muted">
            {group.subjects.map((s, i) => (
              <li key={`${s}-${String(i)}`} className="truncate">
                {s}
              </li>
            ))}
          </ul>
        )}
      </div>

      {group.canTrust && state.status !== "done" && (
        <Button
          variant="secondary"
          data-testid={`mailbox-set-aside-trust-${group.domain}`}
          disabled={state.status === "working"}
          onClick={() => void run()}
        >
          {state.status === "working" ? SET_ASIDE_COPY.trustWorking : SET_ASIDE_COPY.trustAction}
        </Button>
      )}
      {state.status === "done" && (
        <p data-testid={`mailbox-set-aside-imported-${group.domain}`} role="status" className="text-xs text-muted">
          {SET_ASIDE_COPY.imported(state.report.ops)}
        </p>
      )}
      {state.status === "failed" && (
        <p role="alert" className="text-xs text-bad">
          {SET_ASIDE_COPY.trustFailed}
        </p>
      )}
    </li>
  );
}
