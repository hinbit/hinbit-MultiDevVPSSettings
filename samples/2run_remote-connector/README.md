# Remote DB + Connector App 2run

This is the runnable smoke-test copy of the template.

## What it does

- serves a small quiz UI
- exposes `/api/health`
- exposes `/api/quiz`
- exposes `/api/quiz/grade`

## Why it exists

This copy is meant to validate that Multidev can install, start, map ports, and serve the app end to end.

## Ports

Use the generated `PORT` from Multidev. The sample runs on that port and should not be hardcoded to localhost:3001.

## Install hints

The sample also includes `VPS-INSTALL.MD` so Multidev can learn about extra nginx route wiring when it exists.
