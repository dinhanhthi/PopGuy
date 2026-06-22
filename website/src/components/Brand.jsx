import { Link } from "react-router-dom";

export function Brand({ compact = false }) {
  return (
    <Link className={`brand ${compact ? "brand--compact" : ""}`} to="/">
      <img src="/popguy-logo.png" alt="" />
      <span>PopGuy</span>
    </Link>
  );
}

