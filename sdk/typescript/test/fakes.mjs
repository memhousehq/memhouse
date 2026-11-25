// SPDX-License-Identifier: Apache-2.0
// A transport that records every request and answers from a list.

export class RecordingTransport {
  /** Each answer is a body (answered with 200) or a `[status, body]` pair. */
  constructor(...answers) {
    this.answers = answers;
    this.requests = [];
    this.closed = false;
  }

  async request(method, path, body, headers) {
    this.requests.push({ method, path, body: body === null ? null : JSON.parse(body), headers });
    const answer = this.answers.length > 0 ? this.answers.shift() : {};
    const [status, payload] = Array.isArray(answer) ? answer : [200, answer];
    return { status, body: typeof payload === "string" ? payload : JSON.stringify(payload) };
  }

  close() {
    this.closed = true;
  }

  get calls() {
    return this.requests.map((r) => `${r.method} ${r.path}`);
  }
}
