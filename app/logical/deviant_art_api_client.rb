# https://github.com/r888888888/danbooru/issues/4144
#
# API requests must send a user agent and must use gzip compression, otherwise
# 403 errors will be returned.

class DeviantArtApiClient < Struct.new(:deviation_id)
  extend Memoist

  COOKIE_PATH = "/home/danbooru/da-cookies.txt"
  COOKIE_FORMAT = :cookiestxt

  def extended_fetch
    Cache.get("da_ef:#{deviation_id}", 55) do
      params = { deviationid: deviation_id, type: "art", include_session: false }
      response = get("https://www.deviantart.com/_napi/da-deviation/shared_api/deviation/extended_fetch", params: params)
      {
        body: response.body.to_s,
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
      response = get(url)
      response.headers[:location]
    end
  end

  def get(*args, **kwargs)
    jar = HTTP::CookieJar.new
    jar.load(COOKIE_PATH, format: COOKIE_FORMAT)
    response = http.cookies(jar).get(*args, **kwargs)
    response.cookies.each { |c|
      jar.add(c)
    }
    jar.save(COOKIE_PATH, format: COOKIE_FORMAT)
    response
  end

  def http
    HTTP.use(:auto_inflate).headers(headers)
  end

  def headers
    {
      "Accept-Encoding" => "gzip",
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:72.0) Gecko/20100101 Firefox/72.0",
    }
  end

  memoize :extended_fetch, :extended_fetch_json, :download_url
end
