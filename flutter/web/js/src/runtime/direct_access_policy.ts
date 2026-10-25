function isIpv4(value: string): boolean {
  const parts = value.split('.');
  if (parts.length !== 4) {
    return false;
  }
  return parts.every((part) => {
    if (!/^\d+$/.test(part)) {
      return false;
    }
    const num = Number.parseInt(part, 10);
    return num >= 0 && num <= 255;
  });
}

function isDomain(value: string): boolean {
  if (!value || value.length > 253) {
    return false;
  }
  if (value.includes('..') || value.startsWith('-') || value.endsWith('-')) {
    return false;
  }
  return /^[A-Za-z0-9.-]+$/.test(value);
}

export function isDirectAccessTarget(rawId: string): boolean {
  const target = rawId.trim();
  if (!target || /^\d+$/.test(target)) {
    return false;
  }
  if (target.startsWith('ws://') || target.startsWith('wss://')) {
    return true;
  }
  if (target.includes('/') || target.includes('?') || target.includes('#')) {
    return false;
  }
  if (target.startsWith('[')) {
    const end = target.indexOf(']');
    if (end <= 0) {
      return false;
    }
    const host = target.slice(1, end);
    const rest = target.slice(end + 1);
    if (!host || !host.includes(':')) {
      return false;
    }
    if (!rest) {
      return true;
    }
    if (!rest.startsWith(':')) {
      return false;
    }
    const port = Number.parseInt(rest.slice(1), 10);
    return Number.isInteger(port) && port > 0 && port <= 65535;
  }
  const colonCount = (target.match(/:/g) ?? []).length;
  if (colonCount === 0) {
    return isIpv4(target);
  }
  if (colonCount === 1) {
    const lastColon = target.lastIndexOf(':');
    const host = target.slice(0, lastColon);
    const portRaw = target.slice(lastColon + 1);
    const port = Number.parseInt(portRaw, 10);
    if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) {
      return false;
    }
    return isIpv4(host) || isDomain(host);
  }
  return false;
}

export function assertPeerAuthenticatedRoute(rawId: string): void {
  if (!isDirectAccessTarget(rawId)) {
    return;
  }
  throw new Error(
    'Direct IP access requires a peer-authenticated encrypted direct protocol and is unavailable in the Web client.'
  );
}
