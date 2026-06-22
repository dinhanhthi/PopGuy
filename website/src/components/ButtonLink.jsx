import { ArrowRight, Download, LockKeyhole } from "lucide-react";
import { GitHubIcon } from "./GitHubIcon";

const icons = {
  arrow: ArrowRight,
  download: Download,
  github: GitHubIcon,
  lock: LockKeyhole
};

export function ButtonLink({
  children,
  href,
  icon,
  variant = "primary",
  className = ""
}) {
  const Icon = icon ? icons[icon] : null;

  return (
    <a
      className={`button button--${variant} ${className}`}
      href={href}
      target={href?.startsWith("http") ? "_blank" : undefined}
      rel={href?.startsWith("http") ? "noreferrer" : undefined}
    >
      {Icon ? <Icon aria-hidden="true" size={17} /> : null}
      <span>{children}</span>
    </a>
  );
}
