// SPDX-License-Identifier: Apache-2.0
// A transport that records every request and answers from a list.

class Answer {
  constructor(status, body) {
    this.status = status;
    this.body = body;
  }
}

/** An answer with a status of its own: `withStatus(409, { error: "...", code: "conflict" })`. */
export const withStatus = (status, body) => new Answer(status, body);

export class RecordingTransport {
  /**
   * Each answer is a body, answered with 200, or `withStatus(status, body)`. A body may be
   * any JSON value, an array too (`audit()` answers with one).
   */
  constructor(...answers) {
    this.answers = answers;
    this.requests = [];
    this.closed = false;
  }

  async request(method, path, body, headers) {
    this.requests.push({ method, path, body: body === null ? null : JSON.parse(body), headers });
    const answer = this.answers.length > 0 ? this.answers.shift() : {};
    const [status, payload] = answer instanceof Answer ? [answer.status, answer.body] : [200, answer];
    return { status, body: typeof payload === "string" ? payload : JSON.stringify(payload) };
  }

  close() {
    this.closed = true;
  }

  get calls() {
    return this.requests.map((r) => `${r.method} ${r.path}`);
  }
}
