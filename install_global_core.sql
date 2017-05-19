CREATE SCHEMA IF NOT EXISTS translation_proxy;
CREATE EXTENSION IF NOT EXISTS plsh;
CREATE EXTENSION IF NOT EXISTS plpython2u;

CREATE TYPE translation_proxy.api_engine_type AS ENUM ('google', 'promt', 'bing');

CREATE TABLE translation_proxy.cache(
    id BIGSERIAL PRIMARY KEY,
    source char(2), -- if this is NULL, it need to be detected
    target char(2) NOT NULL,
    q TEXT NOT NULL,
    result TEXT,    -- if this is NULL, it need to be translated
    profile TEXT NOT NULL DEFAULT '',
    created TIMESTAMP NOT NULL DEFAULT now(),
    api_engine translation_proxy.api_engine_type NOT NULL,
    encoded TEXT    -- urlencoded string for GET request. Is null after an successfull translation.
);

CREATE UNIQUE INDEX u_cache_q_source_target ON translation_proxy.cache
    USING btree(md5(q), source, target, api_engine, profile);
CREATE INDEX cache_created ON translation_proxy.cache ( created );
COMMENT ON TABLE translation_proxy.cache IS 'The cache for API calls of the Translation proxy';

--- Disclaimer: this urlencode is unusual -- it doesn't touch most chars (incl. multibytes)
--- to avoid reaching 2K limit for URL in Google API calls.
--- "Regular" urlencode() with multibyte chars support is shown above (commented out block of code).
-- trigger, that URLencodes query in cache, when no translation is given
CREATE OR REPLACE FUNCTION translation_proxy._urlencode_fields()
RETURNS TRIGGER AS $BODY$
  import StringIO
  import re
  # this will never work. use python3
  # https://www.postgresql.org/message-id/569D27E5.90400@v-paul.de
  # body = TD['new']['q']
  body = unicode(body, 'utf-8')
  o = StringIO.StringIO()
  for c in body:
    if c in "$#@*?:+][%&#\\/(){}":
      o.write('%%%0X' % ord(c))
    elif c in "\n\r":
      plpy.debug("trigger %0D")
      o.write('%0D')
    elif ord(c) in ( range(0x7f,0xa5) + [0xa0] ):
      o.write('+')
    elif ord(c) in range(0x00,0x19):
      continue
    else:
      o.write(c)

  body = re.sub( r'(%0D){2,}', "%0D", o.getvalue() )
  o.close()
  if re.search( r"\r|\n|\u000a|\u000d", body ):
    plpy.error( 'Linefeed is still found in string. Also here is a unicode bug in python2')

  TD['new']['encoded'] = body
  return 'MODIFY'
$BODY$ LANGUAGE plpython2u;

CREATE TRIGGER _prepare_for_fetch BEFORE INSERT ON translation_proxy.cache
  FOR EACH ROW
  WHEN (NEW.result IS NULL)
  EXECUTE PROCEDURE translation_proxy._urlencode_fields();

-- cookies, oauth keys and so on
CREATE TABLE translation_proxy.authcache(
  api_engine translation_proxy.api_engine_type NOT NULL,
  creds TEXT,
  updated TIMESTAMP NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX u_authcache_engine ON translation_proxy.authcache ( api_engine );

COMMENT ON TABLE translation_proxy.authcache IS 'Translation API cache for remote authorization keys';

INSERT INTO translation_proxy.authcache (api_engine) VALUES ('google'), ('promt'), ('bing')
  ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION translation_proxy._save_cookie(engine translation_proxy.api_engine_type, cookie TEXT)
RETURNS VOID AS $$
BEGIN
  UPDATE translation_proxy.authcache
    SET ( creds, updated ) = ( cookie, now() )
    WHERE api_engine = engine;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION translation_proxy._load_cookie(engine translation_proxy.api_engine_type)
RETURNS TEXT AS $$
DECLARE
  cookie TEXT;
BEGIN
  SELECT creds INTO cookie FROM translation_proxy.authcache
  WHERE api_engine = engine AND
    updated > ( now() - current_setting('translation_proxy.promt.login_timeout')::INTERVAL )
    AND creds IS NOT NULL AND creds <> ''
  LIMIT 1;
  RETURN cookie;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION translation_proxy._find_detected_language(qs TEXT, engine translation_proxy.api_engine_type)
RETURNS TEXT AS $$
DECLARE
  lng CHAR(2);
BEGIN
  SELECT lang INTO lng FROM translation_proxy.cache
    WHERE api_engine = engine AND q = qs AND lang IS NOT NULL
    LIMIT 1;
  RETURN lng;
END;
$$ LANGUAGE plpgsql;

-- adding new parameter to url until it exceeds the limit of 2000 bytes
CREATE OR REPLACE FUNCTION translation_proxy._urladd( url TEXT, a TEXT ) RETURNS TEXT AS $$
  from urllib import quote_plus
  import StringIO
  body = unicode(a, 'utf-8')
  o = StringIO.StringIO()
  for c in body:
    if c in u"+\]\[%&#\n\r":
      o.write('%%%s' % c.encode('hex').upper())
    elif ord(c) in ( range(0x7f,0xa5) + [0xa0] ):
      o.write('+')
    elif ord(c) in range(0x00,0x19):
      continue
    else:
      o.write(c)

  r = url + o.getvalue()
  o.close()
  if len(r) > 1999 :
    plpy.error('URL length is over, time to fetch.', sqlstate = 'EOURL')
  return r
$$ LANGUAGE plpython2u;

-- urlencoding utility
CREATE OR REPLACE FUNCTION translation_proxy._urlencode(q TEXT)
RETURNS TEXT AS $BODY$
import StringIO
body = unicode(q, 'utf-8')
o = StringIO.StringIO()
for c in body:
  if c in u"+\]\[%&#\n\r":
    o.write('%%%s' % c.encode('hex').upper())
  elif ord(c) in ( range(0x7f,0xa5) + [0xa0] ):
    o.write('+')
  elif ord(c) in range(0x00,0x19):
    continue
  else:
    o.write(c)
  body = o.getvalue()
  o.close()
  return body
$BODY$ LANGUAGE plpython2u;
