// infer.imdusd.com's pages for soft navigation (../soft.tsx): moving between them keeps the document, so
// the background, the music and the wallet carry on. /buy/ and /97/ stand alone (cards inside posts).
import type { ReactNode } from "react";
import type { Route } from "../soft";
import { WalletFrame } from "./ui";

export const INFER_ROUTES: Route[] = [
  { path: "", load: () => import("./App").then((m) => m.App) },
  { path: "claim/", load: () => import("./Claim").then((m) => m.Claim) },
  { path: "tokenomics/", load: () => import("./Tokenomics").then((m) => m.Tokenomics) },
];

/** Around every page, mounted once: the site's wallet. */
export const inferFrame = (page: ReactNode) => <WalletFrame>{page}</WalletFrame>;
