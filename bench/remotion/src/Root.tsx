import React from 'react';
import {AbsoluteFill, Composition, OffthreadVideo, staticFile, useCurrentFrame} from 'remotion';

const W = 1080, H = 1920, FPS = 30, N = 300;
const clamp = (x: number) => Math.max(0, Math.min(1, x));
const easeOut = (p: number) => 1 - Math.pow(1 - p, 3);
const FONT = 'Helvetica, Arial, sans-serif';

const Title: React.FC = () => {
  const f = useCurrentFrame();
  const t = f / FPS;
  const p1 = easeOut(clamp((f - 10) / 30));
  const p2 = clamp((f - 30) / 30);
  const colors = ['#f43f5e', '#22d3ee', '#facc15'];
  return (
    <AbsoluteFill style={{background: 'linear-gradient(to bottom, #0b1020, #1e1b4b)', fontFamily: FONT}}>
      <div style={{position: 'absolute', left: 0, width: W, top: 760, textAlign: 'center', color: '#fff', fontSize: 160, fontWeight: 800, lineHeight: 1.2, opacity: p1, transform: `translateY(${80 * (1 - p1)}px)`}}>LISBON</div>
      <div style={{position: 'absolute', left: 0, width: W, top: 960, textAlign: 'center', color: '#c7d2fe', fontSize: 56, fontWeight: 400, lineHeight: 1.2, opacity: p2}}>a weekend in light</div>
      {colors.map((c, i) => (
        <div key={i} style={{position: 'absolute', width: 200, height: 200, borderRadius: 100, background: c,
          left: 90 + i * 320 + 60 * Math.sin(t * 1.5 + i), top: 1300 + 40 * Math.cos(t * 2 + i)}} />
      ))}
      <div style={{position: 'absolute', left: 0, top: 1880, height: 16, width: (W * f) / (N - 1), background: '#fff'}} />
    </AbsoluteFill>
  );
};

const Cards: React.FC = () => {
  const f = useCurrentFrame();
  const t = f / FPS;
  return (
    <AbsoluteFill style={{background: '#0a0a0a', fontFamily: FONT}}>
      <div style={{position: 'absolute', left: 190, top: 600, width: 700, height: 700, borderRadius: 350, background: '#7c3aed', filter: 'blur(80px)',
        transform: `translate(${200 * Math.sin(t * 0.8)}px, ${300 * Math.cos(t * 0.6)}px)`}} />
      {Array.from({length: 48}, (_, i) => {
        const col = i % 6, row = Math.floor(i / 6);
        const r = 12 * Math.sin(t * 2 + i * 0.4);
        const s = 0.92 + 0.08 * Math.sin(t * 3 + i * 0.7);
        const h = i * 7.5;
        return (
          <div key={i} style={{position: 'absolute', left: 30 + col * 170, top: 60 + row * 225, width: 150, height: 200, borderRadius: 24,
            background: `linear-gradient(135deg, hsl(${h}, 80%, 60%), hsl(${h + 40}, 80%, 40%))`, boxShadow: '0 20px 40px rgba(0,0,0,0.5)',
            transform: `rotate(${r}deg) scale(${s})`, display: 'flex', alignItems: 'center', justifyContent: 'center',
            color: '#fff', fontSize: 48, fontWeight: 700}}>{i + 1}</div>
        );
      })}
    </AbsoluteFill>
  );
};

const WORDS = 'this is a quick test of captions on top of moving video footage'.split(' ');
const Video: React.FC = () => {
  const f = useCurrentFrame();
  const t = f / FPS;
  const w = Math.min(WORDS.length - 1, Math.floor(t / 0.75));
  const pop = easeOut(clamp((t - w * 0.75) / 0.2));
  return (
    <AbsoluteFill style={{background: '#000', fontFamily: FONT}}>
      <OffthreadVideo src={staticFile('clip.mp4')} style={{width: W, height: H, objectFit: 'cover'}} />
      <div style={{position: 'absolute', left: 0, top: 1500, width: W, height: 260, background: 'rgba(0,0,0,0.55)'}} />
      <div style={{position: 'absolute', left: 0, width: W, top: 1560, textAlign: 'center', color: '#facc15', fontSize: 120, fontWeight: 800, lineHeight: 1.2,
        opacity: pop, transform: `scale(${0.6 + 0.4 * pop})`}}>{WORDS[w]}</div>
    </AbsoluteFill>
  );
};

export const Root: React.FC = () => (
  <>
    <Composition id="Title" component={Title} width={W} height={H} fps={FPS} durationInFrames={N} />
    <Composition id="Cards" component={Cards} width={W} height={H} fps={FPS} durationInFrames={N} />
    <Composition id="Video" component={Video} width={W} height={H} fps={FPS} durationInFrames={N} />
  </>
);
