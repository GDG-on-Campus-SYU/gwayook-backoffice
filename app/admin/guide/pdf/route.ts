import { guidePdf } from "../../../guide/pdf-response";

export async function GET(request: Request) { return guidePdf(request, "staff"); }
