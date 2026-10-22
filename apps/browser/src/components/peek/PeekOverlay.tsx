import { breadcrumb } from "@ardia/core";
import { FadeLabel, Surface } from "@ardia/shell";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { AccessibilityInfo, Animated, Easing, Pressable, StyleSheet, Text, View } from "react-native";
import { hex, layout, useTheme } from "../../lib/theme";
import { useBrowser } from "../../store/browser";
import { useTab } from "../../store/hooks";
import type { Peek } from "../../store/peek";
import { MAX_SPLIT_PANES, splitOf } from "../../store/splits";
import { FindBar } from "../FindBar";
import { springConfig } from "../layout/dockMotion";
import { Favicon, IconButton } from "../primitives";
import { dismissPeek, finishPeek, openPeekAsTab, openPeekInSplit, registerPeekMotion } from "./actions";

export const PEEK_BAR_HEIGHT = 38;
const INSET_FRACTION = 0.055;
const MIN_INSET = 16;
const BUTTON = 28;
const START_SCALE = 0.12;
const GROW = springConfig({ response: 0.22, damping: 0.9 });
const CLOSE_MS = 150;
const EXPAND_MS = 170;

let reduceMotion: boolean | null = null;
const reduceMotionKnown = AccessibilityInfo.isReduceMotionEnabled().then(
  (on) => (reduceMotion = on),
  () => (reduceMotion = false),
);
AccessibilityInfo.addEventListener("reduceMotionChanged", (on) => (reduceMotion = on));

export function peekFrame(width: number, height: number) {
  const x = Math.max(MIN_INSET, Math.round(width * INSET_FRACTION));
  const y = Math.max(MIN_INSET, Math.round(height * INSET_FRACTION));
  return { left: x, top: y, width: Math.max(0, width - 2 * x), height: Math.max(0, height - 2 * y) };
}

export function PeekOverlay({
  windowId,
  width,
  height,
  origin,
  page,
}: {
  windowId: string;
  width: number;
  height: number;
  origin: { x: number; y: number } | null;
  page: (tabId: string) => ReactNode;
}) {
  const peek = useBrowser((s) => s.peeks[windowId]);
  if (!peek || width <= 0 || height <= 0) return null;
  return <PeekCard key={peek.tabId} windowId={windowId} peek={peek} width={width} height={height} origin={origin} page={page} />;
}

function PeekCard({
  windowId,
  peek,
  width,
  height,
  origin,
  page,
}: {
  windowId: string;
  peek: Peek;
  width: number;
  height: number;
  origin: { x: number; y: number } | null;
  page: (tabId: string) => ReactNode;
}) {
  const theme = useTheme();
  const frame = peekFrame(width, height);
  const [motion, setMotion] = useState<"fade" | "grow" | null>(() => (reduceMotion === null ? null : reduceMotion ? "fade" : "grow"));
  const fade = motion === "fade";
  const [progress] = useState(() => new Animated.Value(0));
  const [expand] = useState(() => new Animated.Value(0));
  const leaving = useRef<"close" | "expand" | null>(null);

  const centerX = frame.left + frame.width / 2;
  const centerY = frame.top + frame.height / 2;
  const fromX = peek.from && origin ? Math.min(Math.max(peek.from.x - origin.x, 0), width) : centerX;
  const fromY = peek.from && origin ? Math.min(Math.max(peek.from.y - origin.y, 0), height) : centerY;

  useEffect(() => {
    if (motion) return;
    let live = true;
    void reduceMotionKnown.then(() => live && setMotion(reduceMotion ? "fade" : "grow"));
    return () => void (live = false);
  }, []);

  useEffect(() => {
    if (!motion) return;
    const grow = fade
      ? Animated.timing(progress, { toValue: 1, duration: CLOSE_MS, easing: Easing.out(Easing.quad), useNativeDriver: true })
      : Animated.spring(progress, { toValue: 1, ...GROW, overshootClamping: true, restDisplacementThreshold: 0.001, restSpeedThreshold: 0.01, useNativeDriver: true });
    grow.start();
    const close = () => {
      if (leaving.current) return;
      leaving.current = "close";
      progress.stopAnimation();
      Animated.timing(progress, { toValue: 0, duration: CLOSE_MS, easing: Easing.in(Easing.cubic), useNativeDriver: true }).start(({ finished }) => {
        if (finished) finishPeek(windowId, peek.tabId);
      });
    };
    const grown = (done: () => void) => {
      if (leaving.current === "expand") return;
      leaving.current = "expand";
      progress.stopAnimation();
      progress.setValue(1);
      if (fade) return done();
      Animated.timing(expand, { toValue: 1, duration: EXPAND_MS, easing: Easing.out(Easing.cubic), useNativeDriver: true }).start(done);
    };
    return registerPeekMotion(windowId, close, grown);
  }, [motion]);

  const scaleX = fade
    ? 1
    : Animated.multiply(
        progress.interpolate({ inputRange: [0, 1], outputRange: [START_SCALE, 1] }),
        expand.interpolate({ inputRange: [0, 1], outputRange: [1, width / Math.max(frame.width, 1)] }),
      );
  const scaleY = fade
    ? 1
    : Animated.multiply(
        progress.interpolate({ inputRange: [0, 1], outputRange: [START_SCALE, 1] }),
        expand.interpolate({ inputRange: [0, 1], outputRange: [1, height / Math.max(frame.height, 1)] }),
      );
  const translateX = fade ? 0 : progress.interpolate({ inputRange: [0, 1], outputRange: [fromX - centerX, 0] });
  const translateY = fade ? 0 : progress.interpolate({ inputRange: [0, 1], outputRange: [fromY - centerY, 0] });
  const cardOpacity = fade ? progress : progress.interpolate({ inputRange: [0, 0.35, 1], outputRange: [0, 1, 1] });
  const dim = Animated.multiply(progress, expand.interpolate({ inputRange: [0, 1], outputRange: [1, 0] }));

  return (
    <View style={StyleSheet.absoluteFill} pointerEvents={motion ? "box-none" : "none"}>
      <Animated.View style={[StyleSheet.absoluteFill, { opacity: dim }]}>
        <Pressable
          accessibilityLabel="Close Peek"
          onPress={() => dismissPeek(windowId)}
          style={{ flex: 1, borderRadius: layout.cardRadius, backgroundColor: theme.dark ? "rgba(0,0,0,0.45)" : "rgba(0,0,0,0.25)" }}
        />
      </Animated.View>
      <Animated.View
        style={{
          position: "absolute",
          ...frame,
          opacity: cardOpacity,
          transform: [{ translateX }, { translateY }, { scaleX }, { scaleY }],
        }}
      >
        <Surface
          fill={hex(theme.panel)}
          cornerRadius={layout.cardRadius}
          borderColor={hex(theme.panelBorder)}
          borderWidth={0.5}
          shadowColor="#000000"
          shadowOpacity={theme.panelShadowOpacity}
          shadowRadius={30}
          shadowOffset={[0, 12]}
          style={StyleSheet.absoluteFill}
        />
        <View style={{ flex: 1, borderRadius: layout.cardRadius, overflow: "hidden", backgroundColor: theme.panel }}>
          <PeekBar windowId={windowId} tabId={peek.tabId} />
          <View style={{ flex: 1 }}>
            {page(peek.tabId)}
            <FindBar tabId={peek.tabId} />
          </View>
        </View>
      </Animated.View>
    </View>
  );
}

function PeekBar({ windowId, tabId }: { windowId: string; tabId: string }) {
  const theme = useTheme();
  const tab = useTab(tabId);
  const splitFull = useBrowser((s) => {
    const source = s.peeks[windowId]?.sourceId;
    return (splitOf(s, source)?.tabIds.length ?? 0) >= MAX_SPLIT_PANES;
  });
  if (!tab) return null;
  const host = tab.url ? breadcrumb(tab.url).host : "";
  const title = tab.customTitle || tab.title;
  return (
    <View
      style={{
        height: PEEK_BAR_HEIGHT,
        flexDirection: "row",
        alignItems: "center",
        paddingLeft: 12,
        paddingRight: 5,
        gap: 8,
        borderBottomWidth: StyleSheet.hairlineWidth,
        borderBottomColor: theme.divider,
      }}
    >
      <Favicon url={tab.url} favicon={tab.favicon} profileId={tab.profileId} />
      <View style={{ flex: 1, flexDirection: "row", alignItems: "center" }}>
        <Text accessible accessibilityLabel={host ? `Peek: ${host}` : "Peek"} numberOfLines={1} style={{ flexShrink: 0, maxWidth: "60%", fontSize: 13, fontWeight: "500", color: theme.textPrimary }}>
          {host}
        </Text>
        {title && title !== host ? <FadeLabel text={`  ${title}`} fontSize={13} color={theme.textSecondary} fadeWidth={14} style={{ flex: 1, height: 18 }} /> : null}
      </View>
      <View style={{ flexDirection: "row", gap: 2 }}>
        <IconButton icon="arrow.up.left.and.arrow.down.right" size={13} box={BUTTON} radius={7} tooltip="Open as Tab (⌘O)" onPress={() => openPeekAsTab(windowId)} />
        <IconButton icon="rectangle.split.2x1" size={14} box={BUTTON} radius={7} disabled={splitFull} tooltip="Open in Split View" onPress={() => openPeekInSplit(windowId)} />
        <IconButton icon="xmark" size={13} box={BUTTON} radius={7} tooltip="Close (Esc)" onPress={() => dismissPeek(windowId)} />
      </View>
    </View>
  );
}
