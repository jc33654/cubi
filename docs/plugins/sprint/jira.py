"""Jira Cloud REST, with the account from ~/.config/atlassian/netrc (machine <site>)."""
import base64
import json
import netrc
import os
import urllib.error
import urllib.parse
import urllib.request


class JiraError(Exception):
    pass


class Jira:
    def __init__(self, site, netrc_path, timeout=15):
        self.site = site
        self.netrc_path = os.path.expanduser(netrc_path)
        self.timeout = timeout

    def _auth(self):
        try:
            login, _, password = netrc.netrc(self.netrc_path).authenticators(self.site) or (None, None, None)
        except (FileNotFoundError, netrc.NetrcParseError) as e:
            raise JiraError(f"讀不到 {self.netrc_path}：{e}")
        if not login or not password:
            raise JiraError(f"{self.netrc_path} 沒有 {self.site} 的帳密")
        return "Basic " + base64.b64encode(f"{login}:{password}".encode()).decode()

    def api(self, method, path, body=None, query=None):
        url = f"https://{self.site}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": self._auth(), "Accept": "application/json",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            if e.code in (401, 403):
                raise JiraError("Jira 認證失敗（401/403），檢查 netrc 的帳號與 token")
            raise JiraError(f"{method} {path} → HTTP {e.code} {detail}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise JiraError(f"連不上 Jira：{e}")
        return json.loads(raw) if raw else None

    def search(self, jql, fields):
        issues, token = [], None
        while True:
            body = {"jql": jql, "fields": fields, "maxResults": 100}
            if token:
                body["nextPageToken"] = token
            page = self.api("POST", "/rest/api/3/search/jql", body)
            issues += page.get("issues", [])
            token = page.get("nextPageToken")
            if not token or page.get("isLast", True):
                return issues

    def issue(self, key, fields):
        return self.api("GET", f"/rest/api/3/issue/{key}", query={"fields": ",".join(fields)})

    def transitions(self, key):
        return [{"id": t["id"], "name": t["name"]} for t in self.api("GET", f"/rest/api/3/issue/{key}/transitions").get("transitions", [])]

    def transition(self, key, transition_id):
        self.api("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": str(transition_id)}})

    def set_field(self, key, field, value):
        self.api("PUT", f"/rest/api/3/issue/{key}", {"fields": {field: value}})


TICKET_FIELDS = ["summary", "status", "resolutiondate", "labels", "assignee", "updated"]


def parse_issue(issue, points_field):
    """The part of an issue the plugin keeps."""
    f = issue.get("fields", {})
    status = f.get("status") or {}
    category = (status.get("statusCategory") or {}).get("key")
    points = f.get(points_field)
    assignee = f.get("assignee") or {}
    return {
        "key": issue["key"],
        "summary": f.get("summary") or "",
        "status": status.get("name") or "",
        "done": category == "done",
        "estimate": float(points) if isinstance(points, (int, float)) else None,
        "resolutionDate": (f.get("resolutiondate") or "")[:10] or None,
        "labels": f.get("labels") or [],
        "assignee": assignee.get("displayName") or "",
        "updated": f.get("updated") or "",
    }
