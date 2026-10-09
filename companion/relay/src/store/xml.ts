// A strict reader for the small XML documents an S3-compatible listing returns. A store may answer 200 with a
// truncated or malformed body (the ListObjectsV2 documentation says so), so a document that is not complete and
// well-formed is an error, never a shorter answer.

export interface XmlElement {
    name: string;
    children: XmlElement[];
    text: string;
}

export class XmlError extends Error {}

const NAME = '[A-Za-z_][A-Za-z0-9_.:-]*';
const OPEN = new RegExp(`<(${NAME})((?:\\s+${NAME}\\s*=\\s*(?:"[^"<]*"|'[^'<]*'))*)\\s*(/?)>`, 'y');
const CLOSE = new RegExp(`</(${NAME})\\s*>`, 'y');
const DECLARATION = /^﻿?\s*<\?xml[^?]*\?>/;

export function parseXml(text: string): XmlElement {
    let at = DECLARATION.exec(text)?.[0].length ?? 0;
    const stack: XmlElement[] = [];
    let root: XmlElement | null = null;
    while (at < text.length) {
        const lt = text.indexOf('<', at);
        const chunk = text.slice(at, lt < 0 ? text.length : lt);
        if (chunk !== '') {
            const top = stack[stack.length - 1];
            if (top === undefined) {
                if (chunk.trim() !== '') throw new XmlError('text outside the root');
            } else {
                top.text += unescape(chunk);
            }
        }
        if (lt < 0) break;
        at = lt;
        CLOSE.lastIndex = at;
        const close = CLOSE.exec(text);
        if (close !== null) {
            const top = stack.pop();
            if (top === undefined || top.name !== close[1]) throw new XmlError('mismatched closing tag');
            at = CLOSE.lastIndex;
            if (stack.length === 0) root = top;
            continue;
        }
        OPEN.lastIndex = at;
        const open = OPEN.exec(text);
        if (open === null) throw new XmlError('malformed tag');
        if (stack.length === 0 && root !== null) throw new XmlError('a second root');
        const element: XmlElement = { name: open[1]!, children: [], text: '' };
        stack[stack.length - 1]?.children.push(element);
        if (open[3] === '/') {
            if (stack.length === 0) root = element;
        } else {
            stack.push(element);
        }
        at = OPEN.lastIndex;
    }
    if (stack.length > 0 || root === null) throw new XmlError('the document is incomplete');
    return root;
}

function unescape(text: string): string {
    return text.replace(/&([^;&]*);|&/g, (_whole, entity: string | undefined) => {
        switch (entity) {
            case 'amp': return '&';
            case 'lt': return '<';
            case 'gt': return '>';
            case 'quot': return '"';
            case 'apos': return "'";
        }
        const code = entity === undefined ? NaN : /^#x[0-9a-fA-F]{1,6}$/.test(entity) ? parseInt(entity.slice(2), 16) : /^#[0-9]{1,7}$/.test(entity) ? parseInt(entity.slice(1), 10) : NaN;
        if (Number.isNaN(code) || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) throw new XmlError('bad entity');
        return String.fromCodePoint(code);
    });
}

/** The children named `name`. */
export function childrenNamed(element: XmlElement, name: string): XmlElement[] {
    return element.children.filter((c) => c.name === name);
}
