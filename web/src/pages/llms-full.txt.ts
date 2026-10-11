import type { APIRoute } from 'astro';
import { llmsFullTxt } from '../data/llms';
import { legalForLlms } from '../lib/legal';

export const GET: APIRoute = async () => new Response(llmsFullTxt(await legalForLlms()), { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
