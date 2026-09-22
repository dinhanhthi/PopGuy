import { GITHUB_URL, RELEASES_URL } from "../constants";

export function Footer() {
  return (
    <footer className="site-footer">
      <a href={`${GITHUB_URL}/blob/main/LICENSE`} target="_blank" rel="noreferrer">AGPLv3</a>
      {" · "}by{" "}
      <a href="https://dinhanhthi.com" target="_blank" rel="noreferrer">Thi</a>
      {" · "}
      <a href={RELEASES_URL} target="_blank" rel="noreferrer">Changelog</a>
    </footer>
  );
}
