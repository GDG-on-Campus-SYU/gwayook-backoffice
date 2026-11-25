"use client";

import { useEffect, useRef, useState } from "react";
import styles from "./display.module.css";

function chime(context: AudioContext, sample = false) {
  const now = context.currentTime;
  const notes = sample ? [784] : [784, 988, 1175];
  const voices = notes.map((frequency, index) => {
    const tone = context.createOscillator();
    const volume = context.createGain();
    const start = now + index * 0.45;
    const duration = sample ? 0.24 : index === 2 ? 0.7 : 0.37;
    tone.type = "triangle";
    tone.frequency.value = frequency;
    volume.gain.setValueAtTime(0, start);
    volume.gain.linearRampToValueAtTime(0.75, start + 0.02);
    volume.gain.setValueAtTime(0.75, start + duration * 0.6);
    volume.gain.exponentialRampToValueAtTime(0.001, start + duration);
    tone.connect(volume).connect(context.destination);
    tone.start(start);
    tone.stop(start + duration);
    tone.onended = () => { tone.disconnect(); volume.disconnect(); };
    return tone;
  });
  return () => voices.forEach(tone => tone.stop());
}

export function ManualTimer() {
  const [minutes, setMinutes] = useState("5");
  const [seconds, setSeconds] = useState("0");
  const [endTime, setEndTime] = useState<number | null>(null);
  const [remaining, setRemaining] = useState<number | null>(null);
  const [sound, setSound] = useState(false);
  const [audioError, setAudioError] = useState("");
  const audio = useRef<AudioContext | null>(null);
  const cancelChime = useRef<(() => void) | undefined>(undefined);
  const valid = /^\d{0,3}$/.test(minutes) && /^\d{0,2}$/.test(seconds) && Number(seconds) < 60;
  const duration = valid ? (Number(minutes) * 60 + Number(seconds)) * 1000 : 0;
  const running = endTime !== null;
  const paused = !running && remaining !== null && remaining > 0;
  const shown = Math.ceil((remaining ?? duration) / 1000);
  const clock = [Math.floor(shown / 60), shown % 60].map(value => String(value).padStart(2, "0")).join(":");

  useEffect(() => () => { void audio.current?.close(); audio.current = null; }, []);

  useEffect(() => {
    if (endTime === null) return;
    function tick() {
      const left = Math.max(0, endTime! - Date.now());
      setRemaining(left);
      if (left > 0) return;
      window.clearInterval(interval);
      setEndTime(null);
      if (sound && audio.current?.state === "running") {
        cancelChime.current?.();
        cancelChime.current = chime(audio.current);
      }
    }
    const interval = window.setInterval(tick, 100);
    return () => window.clearInterval(interval);
  }, [endTime, sound]);

  async function enableAudio(cue: "sample" | "alarm" | "silent") {
    setAudioError("");
    try {
      const context = audio.current ??= new AudioContext();
      await context.resume();
      if (audio.current === context && cue !== "silent") {
        cancelChime.current?.();
        cancelChime.current = chime(context, cue === "sample");
      }
    } catch { setAudioError("종료음을 재생할 수 없습니다. 브라우저의 소리 설정을 확인해 주세요."); }
  }

  function start() {
    const left = paused ? remaining! : duration;
    if (left <= 0) return;
    setRemaining(left);
    setEndTime(Date.now() + left);
    if (sound) void enableAudio(paused ? "silent" : "sample");
  }

  function reset() {
    setEndTime(null);
    setRemaining(null);
    setAudioError("");
  }

  return <section className={styles.manual} aria-labelledby="manual-timer-title">
    <div className={styles.readout}>
      <h2 id="manual-timer-title">수동 타이머</h2>
      <p className={styles.digits} role="timer" aria-label="남은 시간">{clock}</p>
      <p role="status" className={styles.timerState}>{running ? "진행 중" : paused ? "일시정지 중" : remaining === 0 ? "시간 종료" : ""}</p>
    </div>
    <div className={styles.settings}>
      <div className={styles.duration}>
        <label><span>분</span><input aria-label="분" type="number" min="0" max="999" value={minutes} disabled={running || paused}
          onChange={event => { setMinutes(event.target.value); reset(); }} /></label>
        <label><span>초</span><input aria-label="초" type="number" min="0" max="59" value={seconds} disabled={running || paused}
          onChange={event => { setSeconds(event.target.value); reset(); }} /></label>
      </div>
      {!valid && <p role="alert">분은 0~999, 초는 0~59 사이의 정수로 입력하세요.</p>}
      <div className={styles.soundRow}>
        <label><input type="checkbox" checked={sound} disabled={running} onChange={event => setSound(event.target.checked)} /> 종료음</label>
        <button type="button" onClick={() => void enableAudio("alarm")}>미리 듣기</button>
      </div>
      <div className={styles.timerActions}>
        <button type="button" disabled={duration <= 0} onClick={() => {
          if (!running) return start();
          setRemaining(Math.max(0, endTime - Date.now()));
          setEndTime(null);
        }}>{running ? "일시정지" : paused ? "재개" : "시작"}</button>
        <button type="button" disabled={remaining === null} onClick={reset}>초기화</button>
      </div>
      {audioError && <p role="alert">{audioError}</p>}
    </div>
  </section>;
}
