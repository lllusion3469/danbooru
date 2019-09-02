# https://github.com/r888888888/danbooru/issues/4144
#
# API requests must send a user agent and must use gzip compression, otherwise
# 403 errors will be returned.

class DeviantArtApiClient < Struct.new(:deviation_id)
  extend Memoist

  def extended_fetch
    Cache.get("da_ef:#{deviation_id}", 55) do
      params = { deviationid: deviation_id, type: "art", include_session: false }
      response = http.get("https://www.deviantart.com/_napi/da-deviation/shared_api/deviation/extended_fetch", params: params)
      {
        body: response.body.to_s,
        cookies: response.cookies.cookies,
        code: response.code,
        headers: response.headers.to_h,
      }
    end
  end

  def extended_fetch_json
    JSON.parse(extended_fetch[:body]).with_indifferent_access
  end

  def download_url
    Cache.get("da_dl:#{deviation_id}", 55) do
      url = extended_fetch_json.dig(:deviation, :extended, :download, :url)
      response = http.cookies(extended_fetch[:cookies]).get(url)
      response.headers[:location]
    end
  end

  def http
    HTTP.use(:auto_inflate).headers(Danbooru.config.http_headers.merge("Accept-Encoding" => "gzip"))
  end

  memoize :extended_fetch, :extended_fetch_json, :download_url
end
