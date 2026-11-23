<?php
/*
* QQ音乐 NEW-HOT
* By: JW.
* 参数说明: id=QQ音乐id(例如：003aAYrm3GE0Ac)
            level(音质标识) : standard 标准 Mgg, exhigh 超高 Mgg, lossless 无损 Mflac, hires 高解析无损 Mflac, zpyz 臻品音质 Mflac, zpqj 臻品全景声 Mflac, dolby 杜比全景声 Mmp4, jymaster 臻品母带 Mflac
*/
//error_reporting(0);
header('Access-Control-Allow-Origin:*');
header('Content-type:application/json; charset=utf-8');

define("UrlCDN", "https://aqqmusic.tc.qq.com/");

$id = isset($_REQUEST['id']) ? $_REQUEST['id'] : "";
$level = isset($_REQUEST['level']) ? $_REQUEST['level'] : "standard";

exit(json_encode(QQMUSIC::Main($id, $level), 448));

class QQMUSIC
{

	public static function Main($mid, $level)
	{
		$musicInfo = self::GetSongInfo($mid);
		$musicLevelAndSize = self::GetSongRealLevelAndSize($musicInfo, $level);
		$musicfilesize = $musicLevelAndSize[1];

		if ($musicfilesize == 0) {
		    $Array = [
				'code' => 401,
				'msg' => '解析失败，该歌曲无该音质'
			];
			return $Array;
		}
		
		$level = $musicLevelAndSize[0];
		
		$musicSize = round($musicfilesize / 1024 / 1024, 2) . "MB";
		$musicinterval = (int)($musicInfo['interval'] / 60) . "分" . $musicInfo['interval'] % 60 . "秒";
		$tmp = 1002;
		$musickbps = intval($musicfilesize / $tmp * 8 / $musicInfo['interval']) . "kbps";
		$musicQuality = self::GetSongQuality($level);
		
		$music = self::GetSongUrl($mid, self::GetSongFilename($musicInfo, $level));
		$musicUrl = $music['url'];
		$musicEkey = $music['ekey'];
		
		if (!empty($musicInfo['file'])) {
		    $data = [
				'songname' => $musicInfo['name'],
				'singer' => $musicInfo['singer'][0]['name'],
				'album' => $musicInfo['album']['name'],
				'name' => $musicInfo['singer'][0]['name'] . ' - ' . $musicInfo['name'],
				'quality' => $musicQuality,
				'interval' => $musicinterval,
				'size' => $musicSize,
				'kbps' => $musickbps,
				'cover' => 'https://y.qq.com/music/photo_new/T0' . ($musicInfo['mid'] ? '02' : ($musicInfo["vs"][1] ? '62' : '01')) . 'R800x800M000' . ($musicInfo["album"]["mid"] ?: ($musicInfo["vs"][1]?:$musicInfo["singer"][0]["mid"])) . '.jpg',
				'url' => $musicUrl ?: null,
				'ekey' => $musicEkey ?: null
			];
			$Array = [
				'code'=> 200,
				'msg'=> '解析成功',
				'data'=> $data
			];
		} else {
			$Array = [
				'code' => 201,
				'msg' => '解析失败，该歌曲可能无音源'
			];
		}
		return $Array;
	}


	//获取音乐信息
	private static function GetSongInfo($mid)
	{
		$qqmusic_api = 'http://u.y.qq.com/cgi-bin/musicu.fcg';
		$songInfo_data = '{"comm": {"ct": 6,"cv": 200000000,"uin": 0,"guid": 0},"music": {"method": "GetTrackInfo","module": "track_info.UniformRuleCtrlServer","param": {"mids": ["' . $mid . '"],"types": [1]}}}';
		$MusicInfoData = json_decode(self::MloocCurlPost($songInfo_data, $qqmusic_api, 'https://y.qq.com/'), true);
		return $MusicInfoData['music']['data']['tracks'][0];
	}

	//根据音质计算出filename
	private static function GetSongFilename($MusicInfo, $level = "standard")
	{
		$vs = $MusicInfo['vs'];
		$type = $MusicInfo['type'];
		$media_mid = $MusicInfo['file']['media_mid'];
		$file = "";
		switch ($level) {
			case "low":
				$file .= "O4M0";
				break;
			case "standard":
				$file .= "O6M0";
				break;
			case "exhigh":
				$file .= "O8M0";
				break;
			case "dolby":
				$file .= "D0M1";
				break;
			case "lossless":
				$file .= "F0M0";
				break;
			case "hires":
				$file .= "RSM1";
				break;
			case "zpyz":
				$file .= "Q0M0";
				break;
			case "zpqj":
				$file .= "Q0M1";
				break;
			case "jymaster":
				$file .= "AIM0";
				break;
			default:
				$file .= "O6M0";
				break;
		}
		switch ($level) {
			case "jymaster":
				$file .= $vs[3];
				break;
			case "zpyz":
			case "zpqj":
				$file .= $vs[4];
				break;
			default:
				$file .= $media_mid;
				break;
		}
		switch ($level) {
			case "low":
			case "standard":
			case "exhigh":
				$file .= ".mgg";
				break;
			case "dolby":
				$file .= ".mmp4";
				break;
			case "lossless":
			case "hires":
			case "zpyz":
			case "zpqj":
			case "jymaster":
				$file .= ".mflac";
				break;
			default:
				$file .= ".mgg";
				break;
		}
		return $file;
	}
	
	private static function GetSongRealLevelAndSize($musicInfo, $level = "standard") {
	    $lowerLevels = [
	        "jymaster" => "zpqj",
	        "zpqj" => "zpyz",
	        "dolby" => "zpyz",
	        "zpyz" => "hires",
	        "hires" => "lossless",
	        "lossless" => "exhigh",
	        "exhigh" => "standard",
	        "standard" => "low"
	    ];
	    $currentSize = self::GetSongSize($musicInfo, $level);
	    if ($level !== "low" && $currentSize === 0) {
	        return self::GetSongRealLevelAndSize($musicInfo, isset($lowerLevels[$level]) ? $lowerLevels[$level] : "standard");
	    }
	    return [$level, $currentSize];
	}
	
	//获取音乐大小
	private static function GetSongSize($musicInfo, $level = "standard")
	{
		$data = $musicInfo['file'];
		$newSize = $data["size_new"] ?? [];
		$songSize = 0;
		
		switch ($level) {
			case "low":
				$songSize = $data['size_96ogg'];
				break;
			case "standard":
				$songSize = $data['size_128mp3'];
				break;
			case "exhigh":
				$songSize = $data['size_320mp3'];
				break;
			case "dolby":
				$songSize = $data['size_dolby'];
				break;
			case "lossless":
				$songSize = $data['size_flac'];
				break;
			case "hires":
				$songSize = $data['size_hires'];
				break;
			case "zpyz":
				$songSize = !isset($newSize[1]) ? 0 : $newSize[1];
				break;
			case "zpqj":
				$songSize = !isset($newSize[2]) ? 0 : $newSize[2];
				break;
			case "jymaster":
				$songSize = !isset($newSize[0]) ? 0 : $newSize[0];
				break;
		}
		
		return $songSize;
	}

	//根据音乐大小判断音质类型
	private static function GetSongQuality($level)
	{
	    $qualityName = "";
		switch ($level) {
			case "low":
				$qualityName = "低音质";
				break;
			case "standard":
				$qualityName = "标准音质";
				break;
			case "exhigh":
				$qualityName = "超高音质";
				break;
			case "dolby":
				$qualityName = "杜比全景声";
				break;
			case "lossless":
				$qualityName = "无损音质";
				break;
			case "hires":
				$qualityName = "高解析无损";
				break;
			case "zpyz":
				$qualityName = "臻品音质 2.0";
				break;
			case "zpqj":
				$qualityName = "臻品全景声 ,3.0";
				break;
			case "jymaster":
				$qualityName = "臻品母带 4.0";
				break;
			default:
				$qualityName = "标准音质";
				break;
		}
		return $qualityName;
	}

	//获取音乐链接
	private static function GetSongUrl($mid, $filename)
	{
	    $pmidCacheFile = dirname(__FILE__) . '/_pmid.json';
        $pmidJson = json_decode(file_get_contents($pmidCacheFile), true);
	    $pmid = $pmidJson["mid"];
	    
		$post_data = '{"comm": {"ct": 6,"cv": 200000000,"uin": 0,"guid": ""},"music": {"method": "CgiGetHotVkey","module": "music.vkey.GetEVkey","param": {"filename": ["' . $filename . '"],"songmid": ["' . $pmid . '"]}},"ekey":{"method":"GetEkey","module": "music.vkey.GetEVkey","param":{"finfo":[{"filename":"' . $filename . '","mid":"' . $mid . '"}]}}}';
		$MusicData = json_decode(self::MloocCurlPost($post_data, "http://u.y.qq.com/cgi-bin/musicu.fcg", 'https://y.qq.com/'), true);
		
		//开始拼接音乐地址
		$purl = $MusicData['music']['data']['urls'][0]['purl'];
		if (!empty($purl)) $purl = UrlCDN . $purl . '&redirect=1';
		$songmid = $MusicData['music']['data']['urls'][0]['songmid'];
		$ekey = $MusicData['ekey']['data']['ekeyinfo'][0]['ekey'];
		
		return [
		    "url" => $purl,
		    "ekey" => $ekey
		];
	}
	
	//封装的Post方法
	public static function MloocCurlPost($post_data = '', $url = '', $ifurl = '', $UserAgent = '')
	{
		$curl = curl_init();
		curl_setopt($curl, CURLOPT_URL, $url);
		curl_setopt($curl, CURLOPT_USERAGENT, $UserAgent);
		if ($ifurl != '') {
			curl_setopt($curl, CURLOPT_REFERER, $ifurl);
		}
		#关闭SSL
		curl_setopt($curl, CURLOPT_SSL_VERIFYPEER, false);
		curl_setopt($curl, CURLOPT_SSL_VERIFYHOST, false);
		#返回数据不直接显示
		curl_setopt($curl, CURLOPT_RETURNTRANSFER, 1);
		curl_setopt($curl, CURLOPT_POST, 1);
		curl_setopt($curl, CURLOPT_POSTFIELDS, $post_data);
		$response = curl_exec($curl);
		curl_close($curl);
		return $response;
	}
}
