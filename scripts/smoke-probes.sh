# shellcheck shell=bash
# Jellyfin：sso=none。上游 12.4 没有原生 OIDC，测试实例经 Startup API 创建管理员。
# shellcheck disable=SC2154 # work 由 scripts/smoke.sh 提供

web_assert() { grep -qiE 'jellyfin|setup|wizard'; }

before_install() {
  # runner 上没有 ffmpeg：用清单里的 jellyfin 镜像自带的 jellyfin-ffmpeg 生成（一次性的临时容器，
  # 共享文件夹以可写挂给容器，产物落在 media 共享的宿主目录，应用侧只读挂载）。
  local share ref
  share="$SMOKE_DIR/.wonton/data/shares/media"
  ref="$(awk '/^ *image: /{print $2}' "$SMOKE_DIR/docker-compose.yml" | head -1)"
  [[ -n "$ref" ]] || { echo "清单里没有 jellyfin 镜像"; return 1; }
  mkdir -p "$share" || { echo "创建 media 共享文件夹失败：$share"; return 1; }
  docker run --rm --user "$(id -u):$(id -g)" -v "$share:/out" "$ref" \
    /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i color=c=blue:s=320x180:d=3 \
    -f lavfi -i sine=frequency=440:duration=3 \
    -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart \
    /out/e2e-test.mp4 || { echo "容器里生成测试视频失败"; return 1; }
}

_jf_password='wonton-e2e-password'
_jf_auth='Client="Wonton Smoke", Device="smoke", DeviceId="wonton-smoke", Version="1.0.0"'

_jf_login() { # AuthenticateByName；成功时登录响应打到 stdout，失败非 0
  local body
  body="$(jq -nc --arg name "$SMOKE_OWNER" --arg pw "$_jf_password" '{Username:$name,Pw:$pw}')"
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: MediaBrowser $_jf_auth" \
    -H 'Content-Type: application/json' -d "$body" "$SMOKE_WEB_URL/Users/AuthenticateByName"
}

_jf_startup() { # 首启流程：等应用就绪、经 Startup API 建管理员、完成引导；实例已初始化时不用走
  local tries=0 body
  while :; do
    if curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" "$SMOKE_WEB_URL/Startup/User" >/dev/null 2>&1; then
      break
    fi
    tries=$((tries + 1))
    ((tries >= 15)) && { echo "GET /Startup/User 失败（重试 $tries 次）"; return 1; }
    sleep 2
  done
  body="$(jq -nc --arg name "$SMOKE_OWNER" --arg pw "$_jf_password" '{Name:$name,Password:$pw}')"
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
}

_jf_session() { # 输出 "<token> <user_id>"；管理员已存在就直接登录（升级、重装后的实例），没有才走首启。
  # 失败原因打到标准错误，成功数据走标准输出。
  local login
  if login="$(_jf_login 2>/dev/null)"; then
    printf '%s %s' "$(jq -r '.AccessToken // empty' <<<"$login")" "$(jq -r '.User.Id // empty' <<<"$login")"
    return 0
  fi
  _jf_startup || return 1
  login="$(_jf_login)" || { echo "管理员登录失败" >&2; return 1; }
  printf '%s %s' "$(jq -r '.AccessToken // empty' <<<"$login")" "$(jq -r '.User.Id // empty' <<<"$login")"
}

identity_check() {
  SMOKE_WEB_URL="${SMOKE_WEB_URL%/}"  # 套件给的地址带尾斜杠，拼路径前剥掉，避免 // 打不进路由
  local share="$SMOKE_DIR/.wonton/data/shares/media"
  local session_auth token user_id me folders item_id headers status

  mkdir -p "$share" || { echo "创建 media 共享文件夹失败：$share"; return 1; }
  [[ -f "$share/e2e-test.mp4" ]] || { echo "测试视频没准备好（before_install 生成失败？）：$share"; return 1; }

  if ! read -r token user_id <<<"$(_jf_session)"; then
    echo "管理员会话建立失败（原因见日志）"; return 1
  fi
  session_auth="MediaBrowser Client=\"Wonton Smoke\", Device=\"smoke\", DeviceId=\"wonton-smoke\", Version=\"1.0.0\", Token=\"$token\""
  [[ -n "$token" && -n "$user_id" ]] || { echo "登录响应没有 AccessToken/User.Id"; return 1; }
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

# 数据：账号、媒体库和播放列表都在插件数据目录（docker-compose.yml 的 ${WONTON_APP_DATA}:/config）。
# data_write 用管理员会话建一个带随机标记的播放列表，标记记进 SMOKE_STATE；data_check 在升级、
# 重装后重新登录，从 Items API 找回播放列表。升级和重装会重建核心，网关会话要重建。
_jf_marker_file() { # 标记文件：SMOKE_STATE 在 dev.sh probes 里是目录，目录里放标记文件
  if [[ -d "${SMOKE_STATE:-}" ]]; then printf '%s/data-marker' "$SMOKE_STATE"; else printf '%s' "${SMOKE_STATE:-}"; fi
}

_jf_full_auth() { # <token>：拼 MediaBrowser Authorization 头
  printf 'MediaBrowser Client="Wonton Smoke", Device="smoke", DeviceId="wonton-smoke", Version="1.0.0", Token="%s"' "$1"
}

data_write() {
  SMOKE_WEB_URL="${SMOKE_WEB_URL%/}"  # 套件给的地址带尾斜杠，拼路径前剥掉，避免 // 打不进路由
  local token user_id session_auth name out
  dweb --fresh / -L >/dev/null || { echo "重建网关会话失败"; return 1; }
  if ! read -r token user_id <<<"$(_jf_session)"; then echo "管理员会话建立失败（原因见日志）"; return 1; fi
  session_auth="$(_jf_full_auth "$token")"
  name="wonton-smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: $session_auth" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg n "$name" --arg u "$user_id" '{Name:$n,Ids:[],UserId:$u}')" \
    "$SMOKE_WEB_URL/Playlists")" || { echo "建播放列表失败：$out"; return 1; }
  jq -e --arg n "$name" '.Id != null and .Id != ""' <<<"$out" >/dev/null || { echo "建播放列表没返回 Id：$out"; return 1; }
  jq -nc --arg id "$(jq -r .Id <<<"$out")" --arg name "$name" '{id:$id,name:$name}' >"$(_jf_marker_file)" ||
    { echo "写不进标记文件 $(_jf_marker_file)"; return 1; }
  echo "已建播放列表 $name"
}

data_check() {
  SMOKE_WEB_URL="${SMOKE_WEB_URL%/}"  # 套件给的地址带尾斜杠，拼路径前剥掉，避免 // 打不进路由
  local token user_id session_auth marker out
  dweb --fresh / -L >/dev/null || { echo "重建网关会话失败"; return 1; }
  if ! read -r token user_id <<<"$(_jf_session)"; then echo "管理员会话建立失败（原因见日志）"; return 1; fi
  session_auth="$(_jf_full_auth "$token")"
  marker="$(cat "$(_jf_marker_file)" 2>/dev/null)" || true
  [[ -n "$marker" ]] || { echo "没有 data_write 留下的标记（SMOKE_STATE=${SMOKE_STATE:-未设置}）"; return 1; }
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "Authorization: $session_auth" \
    "$SMOKE_WEB_URL/Items?IncludeItemTypes=Playlist&Recursive=true")" ||
    { echo "读播放列表失败：$out"; return 1; }
  jq -e --arg id "$(jq -r .id <<<"$marker")" --arg name "$(jq -r .name <<<"$marker")" \
    'any(.Items[]; .Id == $id and .Name == $name)' <<<"$out" >/dev/null ||
    { echo "播放列表 $(jq -r .name <<<"$marker") 不见了：$(head -c 200 <<<"$out")"; return 1; }
  echo "播放列表 $(jq -r .name <<<"$marker") 还在"
}
