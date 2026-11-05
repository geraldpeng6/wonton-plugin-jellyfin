# Jellyfin：sso=none。上游 12.4 没有原生 OIDC，测试实例经 Startup API 创建主人管理员。
SSO=none
MCP=0

web_assert() { grep -qiE 'jellyfin|setup|wizard'; }

before_install() {
  command -v ffmpeg >/dev/null 2>&1 || { echo "缺少 ffmpeg，无法生成测试视频"; return 1; }
  nice -n 19 ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i color=c=blue:s=320x180:d=3 \
    -f lavfi -i sine=frequency=440:duration=3 \
    -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart \
    "$work/jellyfin-e2e-test.mp4" || { echo "生成测试视频失败"; return 1; }
}

identity_check() {
  local password='wonton-e2e-password'
  local auth='Client="Wonton Smoke", Device="smoke", DeviceId="wonton-smoke", Version="1.0.0"'
  local share="$SMOKE_DIR/.wonton/data/shares/media"
  local session_auth body login token user_id me folders item_id headers status

  mkdir -p "$share" || { echo "创建 media 共享文件夹失败：$share"; return 1; }
  cp "$work/jellyfin-e2e-test.mp4" "$share/e2e-test.mp4" || { echo "复制测试视频失败"; return 1; }

  local tries=0
  while :; do
    if curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$SMOKE_WEB_URL/Startup/User" >/dev/null 2>&1; then
      break
    fi
    tries=$((tries + 1))
    ((tries >= 15)) && { echo "GET /Startup/User 失败（重试 $tries 次）"; return 1; }
    sleep 2
  done
  body="$(jq -nc --arg name "$SMOKE_OWNER" --arg password "$password" '{Name:$name,Password:$password}')"
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "$body" "$SMOKE_WEB_URL/Startup/User" >/dev/null || {
    echo "POST /Startup/User 失败"; return 1;
  }
  body='{"ServerName":"Jellyfin","UICulture":"zh-CN","MetadataCountryCode":"CN","PreferredMetadataLanguage":"zh-cn"}'
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "$body" "$SMOKE_WEB_URL/Startup/Configuration" >/dev/null || {
    echo "POST /Startup/Configuration 失败"; return 1;
  }
  body='{"EnableRemoteAccess":false}'
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "$body" "$SMOKE_WEB_URL/Startup/RemoteAccess" >/dev/null || {
    echo "POST /Startup/RemoteAccess 失败"; return 1;
  }
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X POST "$SMOKE_WEB_URL/Startup/Complete" >/dev/null || {
    echo "POST /Startup/Complete 失败"; return 1;
  }

  body="$(jq -nc --arg name "$SMOKE_OWNER" --arg password "$password" '{Username:$name,Pw:$password}')"
  login="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: MediaBrowser $auth" \
    -H 'Content-Type: application/json' -d "$body" "$SMOKE_WEB_URL/Users/AuthenticateByName")" || {
    echo "管理员登录失败：$login"; return 1;
  }
  token="$(jq -r '.AccessToken // empty' <<<"$login")"
  user_id="$(jq -r '.User.Id // empty' <<<"$login")"
  session_auth="MediaBrowser Client=\"Wonton Smoke\", Device=\"smoke\", DeviceId=\"wonton-smoke\", Version=\"1.0.0\", Token=\"$token\""
  [[ -n "$token" && -n "$user_id" ]] || { echo "登录响应没有 AccessToken/User.Id：$login"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: $session_auth" "$SMOKE_WEB_URL/Users/Me")" || {
    echo "GET /Users/Me 失败：$me"; return 1;
  }
  jq -e --arg name "$SMOKE_OWNER" '.Name == $name and .Policy.IsAdministrator == true' <<<"$me" >/dev/null || {
    echo "当前用户不是主人管理员：$me"; return 1;
  }

  folders="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: $session_auth" \
    "$SMOKE_WEB_URL/Library/VirtualFolders")" || { echo "读取媒体库失败：$folders"; return 1; }
  if ! jq -e 'any(.[]; .Locations[]? == "/media")' <<<"$folders" >/dev/null; then
    curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: $session_auth" \
      -X POST "$SMOKE_WEB_URL/Library/VirtualFolders?name=Media&collectionType=mixed&paths=%2Fmedia&refreshLibrary=true" >/dev/null || {
      echo "创建 /media 媒体库失败"; return 1;
    }
  fi

  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: $session_auth" \
    -X POST "$SMOKE_WEB_URL/Library/Refresh" >/dev/null || { echo "触发媒体扫描失败"; return 1; }

  item_id=''
  for _ in $(seq 1 60); do
    folders="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: $session_auth" \
      --get --data-urlencode 'Recursive=true' --data-urlencode 'Fields=Path' \
      --data-urlencode "UserId=$user_id" "$SMOKE_WEB_URL/Items" 2>/dev/null || true)"
    item_id="$(jq -r '.Items[]? | select(.Path == "/media/e2e-test.mp4") | .Id' <<<"$folders" | head -1)"
    [[ -n "$item_id" ]] && break
    sleep 2
  done
  [[ -n "$item_id" ]] || {
    echo "扫描不到 /media/e2e-test.mp4"
    echo "共享目录：$(ls -la "$share" 2>&1 || true)"
    echo "媒体库：$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "Authorization: $session_auth" "$SMOKE_WEB_URL/Library/VirtualFolders" 2>&1 || true)"
    echo "Items：$folders"
    return 1
  }

  headers="$(mktemp)"
  status="$(curl -sS --noproxy '*' -o /dev/null -D "$headers" -w '%{http_code}' -b "$SMOKE_JAR" \
    -H "Authorization: $session_auth" -H 'Range: bytes=0-31' \
    "$SMOKE_WEB_URL/Videos/$item_id/stream.mp4?Static=true")" || {
    rm -f "$headers"; echo "Range 请求失败"; return 1;
  }
  grep -qi '^HTTP/[^ ]* 206' "$headers" || { rm -f "$headers"; echo "Range 响应不是 206（HTTP $status）"; return 1; }
  grep -qi '^Content-Range: bytes 0-31/' "$headers" || { rm -f "$headers"; echo "响应没有预期 Content-Range"; return 1; }
  rm -f "$headers"
  echo "主人 $SMOKE_OWNER 管理员、媒体扫描和 32 字节 Range 请求通过（item $item_id）"
}
