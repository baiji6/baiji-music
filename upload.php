<?php
/**
 * 白姬音乐 · 数据接收与可视化面板（upload.php）
 *
 * 功能：
 *  1. 接收 App 上报的 JSON 事件（GUID / 平台 / 搜索 / 歌曲 / 音质 / 播放链接）；
 *  2. 落库存储：优先 SQLite（pdo_sqlite），不可用时自动降级为 JSON 文件；
 *  3. 自带图形界面：统计卡片 + 平台分布 + 搜索热词 + 用户列表 + 明细表格；
 *  4. 页面每 10 秒自动刷新（fetch 局部刷新，不整页闪烁）。
 *
 * 部署：把本文件放到网站根目录（可与 index.html 并存），
 *      确保 data/ 目录可写（脚本会自动创建）。
 * 访问：http://<你的域名>/upload.php
 *
 * 依赖：PHP 7.4+。SQLite 可选（没有则用 JSON 文件存储，功能一致）。
 */

declare(strict_types=1);

const DATA_DIR   = __DIR__ . '/data';
const DB_FILE    = DATA_DIR . '/baiji.db';
const JSON_FILE  = DATA_DIR . '/baiji.json';
const MAX_ROWS   = 5000;      // 明细最多保留行数
const MAX_EVENTS = 20000;     // 事件最多保留条数

/* ────────────────────────── 存储层 ────────────────────────── */

/**
 * 统一存储接口。
 *
 * 两种实现：
 *  - SqliteStore：宿主有 pdo_sqlite 时使用（性能好，支持并发）；
 *  - JsonStore：没有 SQLite 扩展时使用（纯文件，零依赖）。
 */
interface Store
{
    public function addEvents(string $guid, string $os, string $app, string $ip, array $events): int;

    public function stats(): array;

    public function platformSplit(): array;

    public function hotKeywords(int $limit): array;

    public function users(int $limit): array;

    public function recentPlays(int $limit): array;

    public function recentSearches(int $limit): array;
}

function ensure_data_dir(): void
{
    if (!is_dir(DATA_DIR)) {
        @mkdir(DATA_DIR, 0775, true);
    }
}

/* ---------- SQLite 实现 ---------- */

class SqliteStore implements Store
{
    private PDO $pdo;

    public function __construct()
    {
        ensure_data_dir();
        $this->pdo = new PDO('sqlite:' . DB_FILE);
        $this->pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $this->pdo->exec('PRAGMA journal_mode=WAL');
        $this->pdo->exec(
            'CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT NOT NULL, os TEXT, app TEXT, type TEXT, ip TEXT,
                event_at INTEGER, payload TEXT)'
        );
        $this->pdo->exec(
            'CREATE TABLE IF NOT EXISTS plays (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT NOT NULL, os TEXT, platform TEXT, song_id TEXT,
                song_name TEXT, singer TEXT, album TEXT, quality TEXT,
                play_url TEXT, ip TEXT, played_at INTEGER)'
        );
        $this->pdo->exec(
            'CREATE TABLE IF NOT EXISTS searches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                guid TEXT NOT NULL, os TEXT, platform TEXT, keyword TEXT,
                result_count INTEGER, ip TEXT, searched_at INTEGER)'
        );
        // 旧库迁移：为已存在的表补充 ip 列（列已存在时会报错，忽略即可）
        foreach (['events', 'plays', 'searches'] as $t) {
            try {
                $this->pdo->exec("ALTER TABLE $t ADD COLUMN ip TEXT NOT NULL DEFAULT ''");
            } catch (Throwable $ex) {
                // ignore: duplicate column
            }
        }
        $this->pdo->exec('CREATE INDEX IF NOT EXISTS idx_plays_at ON plays(played_at)');
        $this->pdo->exec('CREATE INDEX IF NOT EXISTS idx_search_at ON searches(searched_at)');
        $this->pdo->exec('CREATE INDEX IF NOT EXISTS idx_events_at ON events(event_at)');
    }

    public function addEvents(string $guid, string $os, string $app, string $ip, array $events): int
    {
        $n = 0;
        $this->pdo->beginTransaction();
        try {
            $insEvent = $this->pdo->prepare(
                'INSERT INTO events (guid, os, app, type, ip, event_at, payload) VALUES (?,?,?,?,?,?,?)'
            );
            $insPlay = $this->pdo->prepare(
                'INSERT INTO plays (guid, os, platform, song_id, song_name, singer, album, quality, play_url, ip, played_at)
                 VALUES (?,?,?,?,?,?,?,?,?,?,?)'
            );
            $insSearch = $this->pdo->prepare(
                'INSERT INTO searches (guid, os, platform, keyword, result_count, ip, searched_at) VALUES (?,?,?,?,?,?,?)'
            );
            foreach ($events as $ev) {
                if (!is_array($ev)) {
                    continue;
                }
                $type = trim_str($ev['type'] ?? 'unknown', 32);
                $time = (int)($ev['time'] ?? now_ms());
                $insEvent->execute([
                    $guid, $os, $app, $type, $ip, $time,
                    json_encode($ev, JSON_UNESCAPED_UNICODE),
                ]);
                $n++;
                if ($type === 'play') {
                    $insPlay->execute([
                        $guid, $os,
                        trim_str($ev['platform'] ?? '', 32),
                        trim_str($ev['song_id'] ?? '', 64),
                        trim_str($ev['song_name'] ?? '', 200),
                        trim_str($ev['singer'] ?? '', 200),
                        trim_str($ev['album'] ?? '', 200),
                        trim_str($ev['quality'] ?? '', 64),
                        trim_str($ev['play_url'] ?? '', 1024),
                        $ip,
                        $time,
                    ]);
                } elseif ($type === 'search') {
                    $insSearch->execute([
                        $guid, $os,
                        trim_str($ev['platform'] ?? '', 32),
                        trim_str($ev['keyword'] ?? '', 200),
                        (int)($ev['result_count'] ?? 0),
                        $ip,
                        $time,
                    ]);
                }
            }
            $this->pdo->commit();
        } catch (Throwable $ex) {
            $this->pdo->rollBack();
            error_log('[upload.php] store error: ' . $ex->getMessage());
            return 0;
        }
        $this->pdo->exec('DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT ' . MAX_EVENTS . ')');
        $this->pdo->exec('DELETE FROM plays WHERE id NOT IN (SELECT id FROM plays ORDER BY id DESC LIMIT ' . MAX_ROWS . ')');
        $this->pdo->exec('DELETE FROM searches WHERE id NOT IN (SELECT id FROM searches ORDER BY id DESC LIMIT ' . MAX_ROWS . ')');
        return $n;
    }

    private function scalar(string $sql)
    {
        $st = $this->pdo->query($sql);
        $row = $st ? $st->fetch(PDO::FETCH_ASSOC) : null;
        return $row ? array_values($row)[0] : 0;
    }

    public function stats(): array
    {
        $dayAgo = now_ms() - 86400000;
        return [
            'total_events' => (int)$this->scalar('SELECT COUNT(*) FROM events'),
            'total_plays'  => (int)$this->scalar('SELECT COUNT(*) FROM plays'),
            'total_search' => (int)$this->scalar('SELECT COUNT(*) FROM searches'),
            'total_users'  => (int)$this->scalar('SELECT COUNT(DISTINCT guid) FROM events'),
            'today_plays'   => (int)$this->scalar('SELECT COUNT(*) FROM plays WHERE played_at >= ' . $dayAgo),
            'today_search'  => (int)$this->scalar('SELECT COUNT(*) FROM searches WHERE searched_at >= ' . $dayAgo),
            'today_users'   => (int)$this->scalar('SELECT COUNT(DISTINCT guid) FROM events WHERE event_at >= ' . $dayAgo),
        ];
    }

    public function platformSplit(): array
    {
        $st = $this->pdo->query('SELECT platform, COUNT(*) AS c FROM plays GROUP BY platform ORDER BY c DESC');
        $out = [];
        foreach ($st ? $st->fetchAll(PDO::FETCH_ASSOC) : [] as $r) {
            $out[] = ['platform' => (string)($r['platform'] ?: '未知'), 'count' => (int)$r['c']];
        }
        return $out;
    }

    public function hotKeywords(int $limit): array
    {
        $st = $this->pdo->query(
            'SELECT keyword, COUNT(*) AS c FROM searches WHERE keyword <> ""
             GROUP BY keyword ORDER BY c DESC, searched_at DESC LIMIT ' . (int)$limit
        );
        $out = [];
        foreach ($st ? $st->fetchAll(PDO::FETCH_ASSOC) : [] as $r) {
            $out[] = ['keyword' => (string)$r['keyword'], 'count' => (int)$r['c']];
        }
        return $out;
    }

    public function users(int $limit): array
    {
        // SQLite 特性：仅有 MAX 聚合时，裸列（os/ip）取自 MAX 那一行
        $st = $this->pdo->query(
            'SELECT guid, os, ip, COUNT(*) AS c, MAX(event_at) AS last_at
             FROM events GROUP BY guid ORDER BY last_at DESC LIMIT ' . (int)$limit
        );
        $out = [];
        foreach ($st ? $st->fetchAll(PDO::FETCH_ASSOC) : [] as $r) {
            $out[] = [
                'guid' => (string)$r['guid'], 'os' => (string)($r['os'] ?: '-'),
                'ip' => (string)($r['ip'] ?: ''), 'events' => (int)$r['c'],
                'last_at' => (int)$r['last_at'],
            ];
        }
        return $out;
    }

    public function recentPlays(int $limit): array
    {
        $st = $this->pdo->query('SELECT * FROM plays ORDER BY id DESC LIMIT ' . (int)$limit);
        return $st ? $st->fetchAll(PDO::FETCH_ASSOC) : [];
    }

    public function recentSearches(int $limit): array
    {
        $st = $this->pdo->query('SELECT * FROM searches ORDER BY id DESC LIMIT ' . (int)$limit);
        return $st ? $st->fetchAll(PDO::FETCH_ASSOC) : [];
    }
}

/* ---------- JSON 文件实现（无 pdo_sqlite 时的降级） ---------- */

class JsonStore implements Store
{
    private array $data = ['events' => [], 'plays' => [], 'searches' => []];

    public function __construct()
    {
        ensure_data_dir();
        if (is_file(JSON_FILE)) {
            $raw = @file_get_contents(JSON_FILE);
            if ($raw !== false && $raw !== '') {
                $j = json_decode($raw, true);
                if (is_array($j)) {
                    foreach (['events', 'plays', 'searches'] as $k) {
                        if (isset($j[$k]) && is_array($j[$k])) {
                            $this->data[$k] = $j[$k];
                        }
                    }
                }
            }
        }
    }

    private function save(): void
    {
        @file_put_contents(
            JSON_FILE,
            json_encode($this->data, JSON_UNESCAPED_UNICODE),
            LOCK_EX
        );
    }

    public function addEvents(string $guid, string $os, string $app, string $ip, array $events): int
    {
        $n = 0;
        foreach ($events as $ev) {
            if (!is_array($ev)) {
                continue;
            }
            $type = trim_str($ev['type'] ?? 'unknown', 32);
            $time = (int)($ev['time'] ?? now_ms());
            $this->data['events'][] = [
                'guid' => $guid, 'os' => $os, 'app' => $app,
                'type' => $type, 'ip' => $ip, 'event_at' => $time,
                'payload' => json_encode($ev, JSON_UNESCAPED_UNICODE),
            ];
            $n++;
            if ($type === 'play') {
                $this->data['plays'][] = [
                    'guid' => $guid, 'os' => $os,
                    'platform' => trim_str($ev['platform'] ?? '', 32),
                    'song_id' => trim_str($ev['song_id'] ?? '', 64),
                    'song_name' => trim_str($ev['song_name'] ?? '', 200),
                    'singer' => trim_str($ev['singer'] ?? '', 200),
                    'album' => trim_str($ev['album'] ?? '', 200),
                    'quality' => trim_str($ev['quality'] ?? '', 64),
                    'play_url' => trim_str($ev['play_url'] ?? '', 1024),
                    'ip' => $ip,
                    'played_at' => $time,
                ];
            } elseif ($type === 'search') {
                $this->data['searches'][] = [
                    'guid' => $guid, 'os' => $os,
                    'platform' => trim_str($ev['platform'] ?? '', 32),
                    'keyword' => trim_str($ev['keyword'] ?? '', 200),
                    'result_count' => (int)($ev['result_count'] ?? 0),
                    'ip' => $ip,
                    'searched_at' => $time,
                ];
            }
        }
        if (count($this->data['events']) > MAX_EVENTS) {
            $this->data['events'] = array_slice($this->data['events'], -MAX_EVENTS);
        }
        if (count($this->data['plays']) > MAX_ROWS) {
            $this->data['plays'] = array_slice($this->data['plays'], -MAX_ROWS);
        }
        if (count($this->data['searches']) > MAX_ROWS) {
            $this->data['searches'] = array_slice($this->data['searches'], -MAX_ROWS);
        }
        $this->save();
        return $n;
    }

    public function stats(): array
    {
        $dayAgo = now_ms() - 86400000;
        $users = [];
        $todayUsers = [];
        foreach ($this->data['events'] as $e) {
            $users[$e['guid']] = true;
            if ($e['event_at'] >= $dayAgo) {
                $todayUsers[$e['guid']] = true;
            }
        }
        $todayPlays = 0;
        $todaySearch = 0;
        foreach ($this->data['plays'] as $p) {
            if ($p['played_at'] >= $dayAgo) {
                $todayPlays++;
            }
        }
        foreach ($this->data['searches'] as $s) {
            if ($s['searched_at'] >= $dayAgo) {
                $todaySearch++;
            }
        }
        return [
            'total_events' => count($this->data['events']),
            'total_plays'  => count($this->data['plays']),
            'total_search' => count($this->data['searches']),
            'total_users'  => count($users),
            'today_plays'  => $todayPlays,
            'today_search' => $todaySearch,
            'today_users'  => count($todayUsers),
        ];
    }

    public function platformSplit(): array
    {
        $c = [];
        foreach ($this->data['plays'] as $p) {
            $k = $p['platform'] ?: '未知';
            $c[$k] = ($c[$k] ?? 0) + 1;
        }
        arsort($c);
        $out = [];
        foreach ($c as $k => $v) {
            $out[] = ['platform' => (string)$k, 'count' => (int)$v];
        }
        return $out;
    }

    public function hotKeywords(int $limit): array
    {
        $c = [];
        foreach ($this->data['searches'] as $s) {
            if ($s['keyword'] === '') {
                continue;
            }
            $c[$s['keyword']] = ($c[$s['keyword']] ?? 0) + 1;
        }
        arsort($c);
        $out = [];
        foreach (array_slice($c, 0, $limit, true) as $k => $v) {
            $out[] = ['keyword' => (string)$k, 'count' => (int)$v];
        }
        return $out;
    }

    public function users(int $limit): array
    {
        $agg = [];
        foreach ($this->data['events'] as $e) {
            $g = $e['guid'];
            if (!isset($agg[$g])) {
                $agg[$g] = ['guid' => $g, 'os' => $e['os'] ?: '-', 'ip' => (string)($e['ip'] ?? ''),
                            'events' => 0, 'last_at' => 0];
            }
            $agg[$g]['events']++;
            // 记录最近一次事件对应的 IP（旧数据可能没有 ip 键，保留原值）
            if ((int)$e['event_at'] >= $agg[$g]['last_at']) {
                $agg[$g]['last_at'] = (int)$e['event_at'];
                if (!empty($e['ip'])) {
                    $agg[$g]['ip'] = (string)$e['ip'];
                }
            }
        }
        uasort($agg, function ($a, $b) {
            return $b['last_at'] <=> $a['last_at'];
        });
        return array_slice(array_values($agg), 0, $limit);
    }

    public function recentPlays(int $limit): array
    {
        return array_slice(array_reverse($this->data['plays']), 0, $limit);
    }

    public function recentSearches(int $limit): array
    {
        return array_slice(array_reverse($this->data['searches']), 0, $limit);
    }
}

function store(): Store
{
    static $s = null;
    if ($s instanceof Store) {
        return $s;
    }
    if (class_exists('PDO') && in_array('sqlite', PDO::getAvailableDrivers(), true)) {
        try {
            $s = new SqliteStore();
            return $s;
        } catch (Throwable $ex) {
            error_log('[upload.php] sqlite 不可用，降级到 JSON: ' . $ex->getMessage());
        }
    }
    $s = new JsonStore();
    return $s;
}

/* ────────────────────────── 工具函数 ────────────────────────── */

function trim_str($v, int $max = 512): string
{
    if ($v === null) {
        return '';
    }
    if (is_array($v) || is_object($v)) {
        $v = json_encode($v, JSON_UNESCAPED_UNICODE);
    }
    $v = (string)$v;
    $v = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F]/u', '', $v) ?? '';
    return mb_strimwidth_safe($v, $max);
}

/**
 * 按字符数截断（不依赖 mbstring）。
 *
 * 部分主机（如面板精简版 PHP）没装 mbstring，直接调用 mb_substr 会致命错误。
 * 这里用正则按 UTF-8 字符切分，兼容性最好；实在切不动（非法 UTF-8）就退回原串。
 */
function mb_strimwidth_safe(string $s, int $max): string
{
    if ($max <= 0) {
        return '';
    }
    if (function_exists('mb_substr')) {
        return mb_substr($s, 0, $max, 'UTF-8');
    }
    $chars = preg_split('//u', $s, -1, PREG_SPLIT_NO_EMPTY);
    if ($chars === false) {
        return substr($s, 0, $max);
    }
    if (count($chars) <= $max) {
        return $s;
    }
    return implode('', array_slice($chars, 0, $max));
}

function now_ms(): int
{
    return (int)round(microtime(true) * 1000);
}

/**
 * 服务端侧的客户端 IP（兜底用）。
 * 优先级：客户端上报 ip 字段 > X-Forwarded-For > X-Real-IP > REMOTE_ADDR。
 * 经 Nginx/CDN 反代时 REMOTE_ADDR 是代理 IP，需先看转发头。
 */
function client_ip(): string
{
    $headers = [
        'HTTP_X_FORWARDED_FOR',
        'HTTP_X_REAL_IP',
        'HTTP_CF_CONNECTING_IP',
        'REMOTE_ADDR',
    ];
    foreach ($headers as $k) {
        if (empty($_SERVER[$k])) {
            continue;
        }
        // X-Forwarded-For 可能是 "client, proxy1, proxy2"，取第一个
        $v = trim(explode(',', (string)$_SERVER[$k])[0]);
        if ($v !== '' && filter_var($v, FILTER_VALIDATE_IP)) {
            return $v;
        }
    }
    return '';
}

function read_json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || $raw === '') {
        return [];
    }
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

/* ────────────────────────── HTTP 入口 ────────────────────────── */

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action = $_GET['action'] ?? '';

if ($method === 'POST') {
    $data = read_json_body();
    $guid = trim_str($data['guid'] ?? '', 64);
    $os   = trim_str($data['os'] ?? '', 32);
    $app  = trim_str($data['app'] ?? 'baiji_music', 64);
    // 客户端上报的 IP；缺失或非法时用服务端看到的地址兜底
    $ip = trim_str($data['ip'] ?? '', 64);
    if ($ip === '' || !filter_var($ip, FILTER_VALIDATE_IP)) {
        $ip = client_ip();
    }
    $events = is_array($data['events'] ?? null) ? $data['events'] : [];
    $n = ($guid === '' || !$events) ? 0 : store()->addEvents($guid, $os, $app, $ip, $events);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode([
        'ok' => $n > 0,
        'stored' => $n,
        'message' => $n > 0 ? 'ok' : 'no valid events',
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'api') {
    $s = store();
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode([
        'stats'       => $s->stats(),
        'platforms'   => $s->platformSplit(),
        'keywords'    => $s->hotKeywords(12),
        'users'       => $s->users(50),
        'plays'       => $s->recentPlays(50),
        'searches'    => $s->recentSearches(50),
        'server_time' => now_ms(),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

/* ────────────────────────── 前端页面 ────────────────────────── */
?>
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>白姬音乐 · 数据面板</title>
<style>
  :root{
    --bg:#0d1117; --panel:#161b22; --panel2:#1c2330; --line:#2a3441;
    --text:#e6edf3; --dim:#8b949e; --accent:#3fb950; --accent2:#58a6ff;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
       font-family:-apple-system,"PingFang SC","Microsoft YaHei",Segoe UI,Roboto,sans-serif}
  header{display:flex;align-items:center;gap:12px;padding:16px 22px;
         border-bottom:1px solid var(--line);background:var(--panel);
         position:sticky;top:0;z-index:10;flex-wrap:wrap}
  header h1{font-size:18px;margin:0;font-weight:700}
  .badge{font-size:12px;color:var(--dim);border:1px solid var(--line);
         border-radius:999px;padding:3px 10px}
  .spacer{flex:1}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--accent);
       display:inline-block;margin-right:6px;
       box-shadow:0 0 0 0 rgba(63,185,80,.6);animation:pulse 2s infinite}
  @keyframes pulse{70%{box-shadow:0 0 0 8px rgba(63,185,80,0)}100%{box-shadow:0 0 0 0 rgba(63,185,80,0)}}
  .wrap{padding:20px;max-width:1400px;margin:0 auto}
  @media(max-width:640px){.wrap{padding:12px}}
  @media(max-width:640px){th,td{max-width:180px;font-size:12px;padding:7px 8px}}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-bottom:20px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
  .card .k{font-size:12px;color:var(--dim)}
  .card .v{font-size:26px;font-weight:700;margin-top:6px}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px}
  @media(max-width:900px){.grid2{grid-template-columns:1fr}}
  .panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden;margin-bottom:16px}
  .panel h2{margin:0;padding:12px 16px;font-size:14px;border-bottom:1px solid var(--line);
            background:var(--panel2);color:var(--dim);font-weight:600;letter-spacing:.5px}
  .panel .body{padding:12px 16px}
  /* ---- 表格：外层 .tw 负责横向滚动，所有列（含最左侧一列）一起滑动 ---- */
  .tw{overflow-x:auto;overflow-y:hidden;-webkit-overflow-scrolling:touch;
      width:100%;max-width:100%}
  .tw::-webkit-scrollbar{height:8px}
  .tw::-webkit-scrollbar-thumb{background:var(--line);border-radius:4px}
  .tw::-webkit-scrollbar-track{background:transparent}
  table{border-collapse:collapse;font-size:13px;width:max-content;min-width:100%}
  th,td{padding:8px 10px;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap;
        overflow:hidden;text-overflow:ellipsis;max-width:280px}
  th{background:var(--panel2);color:var(--dim);font-weight:600;font-size:12px}
  tbody tr:hover{background:#1b2430}
  .tag{display:inline-block;padding:1px 8px;border-radius:999px;font-size:11px;
       border:1px solid var(--line);background:var(--panel2)}
  .tag.qq{color:#4ade80;border-color:#2c5c3c}
  .tag.netease{color:#f87171;border-color:#6b2b2b}
  .tag.kuwo{color:#60a5fa;border-color:#2b4a6b}
  .bar{height:8px;background:var(--panel2);border-radius:4px;overflow:hidden;margin-top:4px}
  .bar>i{display:block;height:100%;background:linear-gradient(90deg,var(--accent2),var(--accent))}
  .swipe-tip{display:none;font-size:11px;color:var(--dim);padding:6px 14px 0;
             text-align:right;letter-spacing:.3px}
  @media(max-width:640px){.swipe-tip{display:block}}
  .kw{display:flex;flex-wrap:wrap;gap:8px}
  .kw span{background:var(--panel2);border:1px solid var(--line);border-radius:999px;
           padding:4px 10px;font-size:12px}
  .kw span b{color:var(--accent2);margin-left:4px}
  .muted{color:var(--dim);font-size:12px}
  a{color:var(--accent2)}
  .footer{text-align:center;color:var(--dim);font-size:12px;padding:18px}
</style>
</head>
<body>
<header>
  <h1>白姬音乐 · 数据面板</h1>
  <span class="badge"><span class="dot"></span>每 10 秒自动刷新</span>
  <div class="spacer"></div>
  <span class="badge" id="lastUpdate">加载中…</span>
</header>

<div class="wrap">
  <div class="cards" id="cards"></div>

  <div class="grid2">
    <div class="panel">
      <h2>平台播放分布</h2>
      <div class="body" id="platformBox"><span class="muted">暂无数据</span></div>
    </div>
    <div class="panel">
      <h2>搜索热词 TOP</h2>
      <div class="body" id="keywordBox"><span class="muted">暂无数据</span></div>
    </div>
  </div>

  <div class="panel">
    <h2>用户（按 GUID 聚合）</h2>
    <div class="body" style="padding:0">
      <div class="swipe-tip">← 左右滑动查看更多列 →</div>
      <div class="tw">
      <table>
        <thead><tr><th>GUID</th><th>系统</th><th>IP</th><th>事件数</th><th>最后活跃</th></tr></thead>
        <tbody id="userBody"></tbody>
      </table>
      </div>
    </div>
  </div>

  <div class="panel">
    <h2>最近播放</h2>
    <div class="body" style="padding:0">
      <div class="swipe-tip">← 左右滑动查看更多列 →</div>
      <div class="tw">
      <table>
        <thead><tr><th>时间</th><th>平台</th><th>歌曲</th><th>歌手</th><th>专辑</th>
          <th>音质</th><th>GUID</th><th>IP</th><th>播放链接</th></tr></thead>
        <tbody id="playBody"></tbody>
      </table>
      </div>
    </div>
  </div>

  <div class="panel">
    <h2>最近搜索</h2>
    <div class="body" style="padding:0">
      <div class="swipe-tip">← 左右滑动查看更多列 →</div>
      <div class="tw">
      <table>
        <thead><tr><th>时间</th><th>平台</th><th>关键词</th><th>结果数</th><th>GUID</th><th>IP</th></tr></thead>
        <tbody id="searchBody"></tbody>
      </table>
      </div>
    </div>
  </div>

  <div class="footer">白姬音乐 v2.4.2 · upload.php 数据面板</div>
</div>

<script>
function esc(s){
  return String(s==null?'':s).replace(/[&<>"']/g,function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
  });
}
function tag(p){
  var cls = p==='qq'?'qq':(p==='netease'?'netease':(p==='kuwo'?'kuwo':''));
  return '<span class="tag '+cls+'">'+esc(p||'未知')+'</span>';
}
function fmtTime(ms){
  if(!ms) return '—';
  var d=new Date(ms); var p=function(n){return n<10?'0'+n:n};
  return p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());
}
function render(d){
  var s=d.stats||{};
  document.getElementById('cards').innerHTML=[
    ['总用户数', s.total_users],
    ['24h 活跃用户', s.today_users],
    ['总事件数', s.total_events],
    ['总播放数', s.total_plays],
    ['24h 播放数', s.today_plays],
    ['24h 搜索数', s.today_search]
  ].map(function(x){return '<div class="card"><div class="k">'+x[0]+'</div><div class="v">'+(x[1]||0)+'</div></div>'}).join('');

  var total=(d.platforms||[]).reduce(function(a,b){return a+b.count},0);
  document.getElementById('platformBox').innerHTML = (d.platforms&&d.platforms.length)
    ? d.platforms.map(function(p){
        var pct= total? Math.round(p.count*100/total):0;
        return '<div style="margin-bottom:10px"><div style="display:flex;justify-content:space-between;font-size:13px">'
          +'<span>'+tag(p.platform)+'</span><span class="muted">'+p.count+' 次 · '+pct+'%</span></div>'
          +'<div class="bar"><i style="width:'+pct+'%"></i></div></div>';
      }).join('')
    : '<span class="muted">暂无数据</span>';

  document.getElementById('keywordBox').innerHTML = (d.keywords&&d.keywords.length)
    ? '<div class="kw">'+d.keywords.map(function(k){
        return '<span>'+esc(k.keyword)+'<b>×'+k.count+'</b></span>';
      }).join('')+'</div>'
    : '<span class="muted">暂无数据</span>';

  document.getElementById('userBody').innerHTML = (d.users&&d.users.length)
    ? d.users.map(function(u){
        return '<tr><td title="'+esc(u.guid)+'">'+esc(u.guid)+'</td><td>'+esc(u.os)+
               '</td><td>'+esc(u.ip||'—')+'</td><td>'+u.events+'</td><td>'+fmtTime(u.last_at)+'</td></tr>';
      }).join('')
    : '<tr><td colspan="5" class="muted">暂无数据</td></tr>';

  document.getElementById('playBody').innerHTML = (d.plays&&d.plays.length)
    ? d.plays.map(function(p){
        var url = p.play_url? '<a href="'+esc(p.play_url)+'" target="_blank" rel="noopener">链接</a>' : '—';
        return '<tr><td>'+fmtTime(p.played_at)+'</td><td>'+tag(p.platform)+'</td>'
          +'<td title="'+esc(p.song_name)+'">'+esc(p.song_name)+'</td>'
          +'<td title="'+esc(p.singer)+'">'+esc(p.singer)+'</td>'
          +'<td title="'+esc(p.album)+'">'+esc(p.album)+'</td>'
          +'<td>'+esc(p.quality)+'</td>'
          +'<td title="'+esc(p.guid)+'">'+esc(p.guid).slice(0,8)+'…</td>'
          +'<td>'+esc(p.ip||'—')+'</td>'
          +'<td>'+url+'</td></tr>';
      }).join('')
    : '<tr><td colspan="9" class="muted">暂无数据</td></tr>';

  document.getElementById('searchBody').innerHTML = (d.searches&&d.searches.length)
    ? d.searches.map(function(s){
        return '<tr><td>'+fmtTime(s.searched_at)+'</td><td>'+tag(s.platform)+'</td>'
          +'<td>'+esc(s.keyword)+'</td><td>'+(s.result_count||0)+'</td>'
          +'<td title="'+esc(s.guid)+'">'+esc(s.guid).slice(0,8)+'…</td>'
          +'<td>'+esc(s.ip||'—')+'</td></tr>';
      }).join('')
    : '<tr><td colspan="6" class="muted">暂无数据</td></tr>';

  document.getElementById('lastUpdate').textContent='最后更新 '+fmtTime(d.server_time);
}
function load(){
  fetch('upload.php?action=api',{cache:'no-store'})
    .then(function(r){return r.json()})
    .then(render)
    .catch(function(e){
      document.getElementById('lastUpdate').textContent='刷新失败: '+e;
    });
}
load();
setInterval(load,10000);   // 每 10 秒自动刷新
</script>
</body>
</html>
