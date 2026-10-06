#!/usr/bin/env python3
"""Build an isolated, instrumented copy; never modify shipping Swift sources."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import queue
import shutil
import statistics
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ".build" / "preview-performance"


def processes():
    rows = subprocess.check_output(
        ["ps", "-axo", "pid=,rss=,time=,comm="], text=True
    ).splitlines()
    result = {}
    for row in rows:
        fields = row.strip().split(None, 3)
        if len(fields) != 4:
            continue
        pid, rss, cpu, command = fields
        minutes, seconds = cpu.split(":")
        result[int(pid)] = {
            "rss_mib": int(rss) / 1024,
            "cpu_seconds": float(minutes) * 60 + float(seconds),
            "command": command,
        }
    return result


def prepare():
    source = OUT / "source"
    source.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["rsync", "-a", "--delete", "--exclude=.git", "--exclude=.build",
         "--exclude=Tests", str(ROOT) + "/", str(source) + "/"], check=True
    )
    delegate = source / "FSNotes/AppDelegate.swift"
    text = delegate.read_text()
    text = text.replace(
        "func applicationWillFinishLaunching(_ notification: Notification) {",
        "func applicationWillFinishLaunching(_ notification: Notification) {\n"
        "        if PreviewPerformance.enabled { PreviewPerformance.configure(); return }",
    )
    text = text.replace(
        "mainWC.window?.makeKeyAndOrderFront(nil)",
        "mainWC.window?.makeKeyAndOrderFront(nil)\n"
        "        if PreviewPerformance.enabled {\n"
        "            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { PreviewPerformance.shared.start() }\n"
        "        }",
        1,
    )
    delegate.write_text(text + "\n" + (ROOT / "Tests/PreviewPerformance/Benchmark.swift").read_text())
    preview = source / "FSNotesCore/MPreviewView.swift"
    preview.write_text(preview.read_text().replace(
        "super.init(frame: frame, configuration: configuration)",
        "super.init(frame: frame, configuration: configuration)\n"
        "        if PreviewPerformance.enabled { PreviewPerformance.shared.track(self) }",
        1,
    ))
    return source


def build(source):
    command = [
        "xcodebuild", "-project", str(source / "FSNotes.xcodeproj"),
        "-scheme", "FSNotes", "-configuration", "Release",
        "-destination", "platform=macOS,arch=" + platform.machine(),
        "-derivedDataPath", str(OUT / "derived"),
        "-clonedSourcePackagesDirPath", str(ROOT / ".build/SourcePackages"),
        "-disableAutomaticPackageResolution", "-quiet",
        "PRODUCT_BUNDLE_IDENTIFIER=es.fsnotes.previewbenchmark",
        "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-",
        "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
        "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE=", "PROVISIONING_PROFILE_SPECIFIER=", "build",
    ]
    print("Building isolated Release app; log:", OUT / "build.log", flush=True)
    with (OUT / "build.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError("Build failed: " + str(OUT / "build.log"))
    return OUT / "derived/Build/Products/Release/FSNotes.app/Contents/MacOS/FSNotes"


def run(executable):
    before = processes()
    env = dict(os.environ, FSNOTES_PREVIEW_BENCHMARK="1")
    app = subprocess.Popen([str(executable)], env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, bufsize=1)
    print("Benchmark PID:", app.pid, flush=True)
    messages = queue.Queue()
    events, snapshots = [], []
    candidates = set()
    verified = set()
    stage = "startup"
    complete = False
    start = time.monotonic()
    raw = (OUT / "runtime.log").open("w")

    def read():
        for line in app.stdout:
            raw.write(line)
            raw.flush()
            if line.startswith("BENCH "):
                messages.put(json.loads(line[6:]))

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        while app.poll() is None:
            if time.monotonic() - start > 600:
                app.terminate()
                raise RuntimeError("Benchmark exceeded 10 minutes")
            while not messages.empty():
                event = messages.get()
                events.append(event)
                stage = event["stage"]
                verified.update(event.get("webkit_pids", []))
                if event["event"] in {"begin", "end", "timeout", "fatal", "complete"}:
                    compact = {key: value for key, value in event.items()
                               if key not in {"render_ms", "sync_fill_ms", "webkit_pids"}}
                    compact["render_count"] = len(event.get("render_ms", []))
                    print(json.dumps(compact, ensure_ascii=False), flush=True)
                if event["event"] == "complete" and not complete:
                    complete = True
                    subprocess.Popen(
                        ["leaks", "--groupByType", "--noContent", str(app.pid)], stdout=(OUT / "leaks.txt").open("w"),
                        stderr=subprocess.STDOUT,
                    )
            current = processes()
            for pid, row in current.items():
                if pid not in before and "/com.apple.WebKit." in row["command"]:
                    candidates.add(pid)
            selected = {pid: row for pid, row in current.items()
                        if pid == app.pid or pid in candidates or pid in verified}
            snapshots.append({"elapsed": time.monotonic() - start, "stage": stage,
                              "processes": selected,
                              "verified_total_rss_mib": sum(row["rss_mib"] for pid, row in selected.items()
                                                            if pid == app.pid or pid in verified),
                              "total_rss_mib": sum(row["rss_mib"] for row in selected.values())})
            time.sleep(0.2)
        reader.join(timeout=2)
        while not messages.empty():
            events.append(messages.get())
    finally:
        raw.close()
        if app.poll() is None:
            app.terminate()
            app.wait(timeout=10)
    result = {"returncode": app.returncode, "complete": complete, "events": events, "samples": snapshots,
              "webkit_candidate_pids": sorted(candidates),
              "webkit_verified_pids": sorted(verified),
              "metric": "sum of app and verified WebKit RSS; shared pages may be counted twice",
              "attribution": "WebKit diagnostic PID getters in the isolated test app; unverified new processes retained as candidates"}
    (OUT / "results.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    summaries = []
    for event in events:
        if event["event"] != "end":
            continue
        samples = [row for row in snapshots if row["stage"] == event["stage"]]
        steady = [row["verified_total_rss_mib"] for row in samples
                  if row["elapsed"] >= samples[-1]["elapsed"] - 1] if samples else []
        render = sorted(event["render_ms"])
        sync = event["sync_fill_ms"]
        summaries.append({
            "stage": event["stage"], "render_count": len(render),
            "render_p50_ms": statistics.median(render) if render else None,
            "render_p95_ms": render[math.ceil(len(render) * .95) - 1] if render else None,
            "sync_p50_ms": statistics.median(sync) if sync else None,
            "steady_rss_mib": statistics.median(steady) if steady else None,
            "main_thread_delay_max_ms": event["max_main_thread_delay_ms"],
            "live_previews": event["live_previews"],
            "live_closed_editors": event["live_closed_editors"],
            "live_closed_text_views": event.get("live_closed_text_views"),
            "live_closed_processors": event.get("live_closed_processors"),
            "failures": event["failures"],
        })
    (OUT / "summary.json").write_text(json.dumps(summaries, indent=2, ensure_ascii=False))
    print("Results:", OUT / "results.json", flush=True)
    if not complete:
        raise RuntimeError("Benchmark app exited before completing all scenarios")
    if app.returncode:
        raise RuntimeError("Benchmark app returned " + str(app.returncode))


def run_parser():
    derived = OUT / "derived"
    if not (derived / "Build/Products/Release/libcmark_gfm.o").exists():
        derived = ROOT / ".build"
    product = derived / "Build/Products/Release"
    module = derived / "Build/Intermediates.noindex/GeneratedModuleMaps/libcmark_gfm.modulemap"
    source = ROOT / "FSNotesCore/Business/Markdown.swift"
    executable = OUT / "parser-current"
    subprocess.run(["swiftc", "-O", "-Xcc", "-fmodule-map-file=" + str(module),
                    str(source), str(ROOT / "Tests/PreviewPerformance/Parser.swift"),
                    str(product / "libcmark_gfm.o"), "-o", str(executable)], check=True)
    log_path = OUT / "parser-current.jsonl"
    with log_path.open("w") as log:
        subprocess.run([str(executable)], stdout=log, check=True)
    rows = [json.loads(line) for line in log_path.read_text().splitlines()]
    # Fixed fixtures protect rendered output while the allocation check catches
    # missing cleanup without depending on the process's startup footprint.
    expected = {
        "small": "2ab235c531d4f00afcc9b653a49f3f9febc80e1ca2a20c830f601773b014450b",
        "long": "c9b58486a7e85c60a39981ca0f76283896d8555859049d2f0ac8d566f6617f3d",
    }
    for name, digest in expected.items():
        summary = next(row for row in rows if row["event"] == "summary" and row["workload"] == name)
        if summary["html_sha256"] != digest:
            raise RuntimeError("Rendered HTML changed for fixture: " + name)
        checkpoints = {row["iteration"]: row["memory"]["physical_footprint_mib"]
                       for row in rows if row["event"] == "checkpoint" and row["workload"] == name}
        growth = checkpoints[100] - checkpoints[10]
        if growth > 8:
            raise RuntimeError(f"Parser memory grew {growth:.1f} MiB after warmup: {name}")
        print(f"Parser {name}: {summary['memory']['physical_footprint_mib']:.1f} MiB; "
              f"post-warmup growth {growth:.2f} MiB; HTML verified", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-only", action="store_true")
    parser.add_argument("--parser-only", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.parser_only:
        run_parser()
        return
    if args.run_only:
        executable = OUT / "derived/Build/Products/Release/FSNotes.app/Contents/MacOS/FSNotes"
    else:
        executable = build(prepare())
    run(executable)
    run_parser()


if __name__ == "__main__":
    main()
