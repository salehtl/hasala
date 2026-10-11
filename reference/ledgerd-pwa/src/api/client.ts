import type { AssignmentSet, MoveBody, Project, ProjectDetail, TargetBody, Txn } from "./types";
import type { EnvelopeSummary } from "../lib/envelope";

async function parseOrThrow(res: Response) {
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) {
    throw new Error(body?.error ?? `request failed: ${res.status}`);
  }
  return body;
}

export async function getJSON<T>(url: string): Promise<T> {
  return parseOrThrow(await fetch(url));
}

export async function postJSON<T = unknown>(url: string, body: unknown, method = "POST"): Promise<T> {
  return parseOrThrow(await fetch(url, {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }));
}

export async function del(url: string): Promise<void> {
  await parseOrThrow(await fetch(url, { method: "DELETE" }));
}

export function getRefundCandidates(id: number): Promise<Txn[]> {
  return getJSON<Txn[]>(`/api/transactions/${id}/refund-candidates`);
}

export async function linkRefund(id: number, targetId: number): Promise<void> {
  await postJSON(`/api/transactions/${id}/link-refund`, { target_id: targetId });
}

export function getProjects(includeCompleted = false): Promise<Project[]> {
  return getJSON<Project[]>(`/api/projects${includeCompleted ? "?include_completed=1" : ""}`);
}

export function getProject(id: number): Promise<ProjectDetail> {
  return getJSON<ProjectDetail>(`/api/projects/${id}`);
}

export function createProject(body: Partial<Project>): Promise<{ id: number }> {
  return postJSON(`/api/projects`, body);
}

export function updateProject(id: number, body: Partial<Project>): Promise<void> {
  return postJSON(`/api/projects/${id}`, body, "PUT");
}

export function deleteProject(id: number): Promise<void> {
  return del(`/api/projects/${id}`);
}

export function assignTxnProject(txnId: number, projectId: number | null): Promise<void> {
  return postJSON(`/api/transactions/${txnId}/project`, { project_id: projectId });
}

export function bulkAssignProject(id: number, ids: number[]): Promise<void> {
  return postJSON(`/api/projects/${id}/assign`, { transaction_ids: ids });
}

// ---- envelopes & targets (plan) --------------------------------------------
// One-shot calls for undo actions that live in toast closures and outlive
// their sheet: a mutation hook's callbacks are dropped once its component
// unmounts, which would leave even a *successful* undo unwritten to the cache.

export function moveMoneyOnce(month: string, body: MoveBody): Promise<EnvelopeSummary> {
  return postJSON<EnvelopeSummary>("/api/envelopes/move", { month, ...body });
}

export function assignEnvelopesOnce(month: string, assignments: AssignmentSet[]): Promise<EnvelopeSummary> {
  return postJSON<EnvelopeSummary>("/api/envelopes/assign", { month, assignments });
}

export function putTargetOnce(categoryId: number, body: TargetBody): Promise<unknown> {
  return postJSON(`/api/targets/${categoryId}`, body, "PUT");
}
