// Pairing link source and secret lifetime (companion-v0 §5.1).
import { decodeB64, isId } from './encoding.ts';

export class PairingLinkError extends Error {
    constructor() { super('This pairing link is invalid.'); }
}
export interface PairingLink {
    relayOrigin: string; pairingId: string; secret: string; ownerPublicKey: Uint8Array; deviceId: string;
}

export function parsePairingLink(fragment: string): PairingLink {
    try {
        if (fragment.length > 4096 || !fragment.startsWith('#pair=v0.')) throw new PairingLinkError();
        const parts = fragment.slice('#pair=v0.'.length).split('.');
        if (parts.length !== 5) throw new PairingLinkError();
        const [encodedOrigin, pairingId, secret, owner, deviceId] = parts as [string, string, string, string, string];
        const originBytes = decodeB64(encodedOrigin), ownerPublicKey = decodeB64(owner);
        if (!originBytes || ownerPublicKey?.length !== 32 || !isId(pairingId) || !isId(secret) || !isId(deviceId))
            throw new PairingLinkError();
        const relayOrigin = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(originBytes);
        const url = new URL(relayOrigin);
        if (url.origin !== relayOrigin || url.username || url.password ||
            !(url.protocol === 'https:' || (url.protocol === 'http:' && url.hostname === 'localhost')))
            throw new PairingLinkError();
        return { relayOrigin, pairingId, secret, ownerPublicKey, deviceId };
    } catch { throw new PairingLinkError(); }
}

/** Remove the fragment before parsing, including malformed links; never place it in history state or errors. */
export function consumePairingLink(location: Pick<Location, 'hash' | 'pathname' | 'search'>,
    history: Pick<History, 'replaceState'>): PairingLink | null {
    const fragment = location.hash;
    if (!fragment) return null;
    history.replaceState(null, '', location.pathname + location.search);
    return parsePairingLink(fragment);
}
