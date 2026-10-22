import { create } from "zustand";
import { switchOn } from "../../lib/killSwitches";
import { layout } from "../../lib/theme";
import { useBrowser, type BrowserState } from "../../store/browser";
import { useWindowId } from "../../store/hooks";

export function useTabLayout(): "sidebar" | "top" {
  const windowId = useWindowId();
  return useBrowser((s) => s.windows[windowId]?.tabLayout ?? s.settings.tabLayout);
}

export function addressBarInSidebar(s: BrowserState, windowId: string): boolean {
  const w = s.windows[windowId];
  return (
    !!w &&
    s.settings.addressBar === "sidebar" &&
    (w.sidebarOpen || switchOn("sidebarSlide")) &&
    (w.tabLayout ?? s.settings.tabLayout) === "sidebar"
  );
}

export function useAddressBarInSidebar(): boolean {
  const windowId = useWindowId();
  return useBrowser((s) => addressBarInSidebar(s, windowId));
}

export const SIDEBAR_FIELD = { top: 48, height: layout.rowHeight, radius: 10 } as const;
export const SIDEBAR_FOOTER_DOWNLOADS = { bottom: 3 + (41 - 3 - 34) / 2, size: 34 } as const;
export function listTopGap(addressBar: boolean): number {
  return addressBar ? 6 : layout.pinnedTop - layout.sidebarHeader;
}

export const SIDEBAR_HEADER_WITH_FIELD = SIDEBAR_FIELD.top + SIDEBAR_FIELD.height;

type UrlAnchor = { left: number; top: number; width: number; sidebar?: { height: number } };

export const useUrlAnchors = create<Record<string, UrlAnchor>>()(() => ({}));

export function setUrlAnchor(windowId: string, anchor: UrlAnchor) {
  const current = useUrlAnchors.getState()[windowId];
  if (current && current.left === anchor.left && current.top === anchor.top && current.width === anchor.width && current.sidebar?.height === anchor.sidebar?.height) return;
  useUrlAnchors.setState({ [windowId]: anchor });
}

type CardAnchor = { left: number; top: number; width: number; height: number };

export const useCardAnchors = create<Record<string, CardAnchor>>()(() => ({}));

export function setCardAnchor(windowId: string, anchor: CardAnchor) {
  const current = useCardAnchors.getState()[windowId];
  if (current && current.left === anchor.left && current.top === anchor.top && current.width === anchor.width && current.height === anchor.height) return;
  useCardAnchors.setState({ [windowId]: anchor });
}

export const useToolbarExtensionsWidths = create<Record<string, number>>()(() => ({}));

export function setToolbarExtensionsWidth(windowId: string, width: number) {
  if (useToolbarExtensionsWidths.getState()[windowId] === width) return;
  useToolbarExtensionsWidths.setState({ [windowId]: width });
}
