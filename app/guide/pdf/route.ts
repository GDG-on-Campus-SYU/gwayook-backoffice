import { guidePdf } from "../pdf-response";

export async function GET(request: Request) { return guidePdf(request, "participant"); }
