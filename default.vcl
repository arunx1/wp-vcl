backend default {
    .host = "127.0.0.1";
    .port = "8000";
.connect_timeout = 600s;
.first_byte_timeout = 600s;
.between_bytes_timeout = 600s;
}
acl purge {
      "localhost";
        "127.0.0.1";
        "Server Public IP";
}
sub vcl_recv {
	
	# set standard proxied ip header for getting original remote address
	set req.http.X-Forwarded-For = client.ip;
	set req.grace = 30m;
	
if (req.request == "PURGE") {
	if (!client.ip ~ purge) {
		error 405 "Not allowed.";
	}
	ban("req.url ~ "+req.url);
	error 200 "Purged";
}

	### NORMALIZE
	
	# Cleanup URLs like /iframe=true&width=90%&height=90% 
	if(req.url ~ "iframe=true(.*)$") {
		set req.url = regsub(req.url,"iframe=true(.*)$","");
		error 301;
	}
	
	# Normalize the url - first remove any hashtags (shouldn't make it to the server anyway, but just in case) 
	if (req.url ~ "\#") {
		set req.url=regsub(req.url,"\#.*$","");
	}


	# Strip out Google Analytics campaign variables. They are only needed
	# by the javascript running on the page
	# utm_source, utm_medium, utm_campaign, gclid
	if(req.url ~ "(\?|&)(gclid|utm_[a-z]+)=") {
		set req.url = regsuball(req.url, "(gclid|utm_[a-z]+)=[-_A-z0-9]+&?", "");
		set req.url = regsub(req.url, "(\?|&)$", "");
	}


	# remove awesm referrers from query string
	if(req.url ~ "(\?|&)awesm=") {
		set req.url = regsub(req.url, "\?.*$", "");
	}

	# remove startIndex from query string
	# not sure what this does
	if(req.url ~ "(\?|&)startIndex=") {
		set req.url = regsub(req.url, "\?.*$", "");
	}


	# remove fb_xd_fragment from query string
	if(req.url ~ "\?fb_xd_fragment") {
		set req.url = regsub(req.url, "\?.*$", "");
	}


	# remove comment-page-1 from query string
	# this is the same page as the post page
	if(req.url ~ "comment-page-1") {
		set req.url = regsub(req.url, "comment-page-1", "");
	}

	# remove double // in urls, 
	set req.url = regsuball( req.url, "//", "/"      );
  
  // remove extra http:// calls at the end of the url
	if (req.url ~ "^/\?http://") {
		set req.url = regsub(req.url, "\?http://.*", "");
	}

	### END NORMALIZE


	# Normalize Content-Encoding
	if (req.http.Accept-Encoding) 
	{
		if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|lzma|tbz)(\?.*|)$") { 
			remove req.http.Accept-Encoding;
		} else if (req.url ~ "\.(js|css|txt|html|htm)(\?.*|)$") {
			# text files - do compression
			if (req.http.Accept-Encoding ~ "gzip") {
				set req.http.Accept-Encoding = "gzip";
			} elsif (req.http.Accept-Encoding ~ "deflate") {
				set req.http.Accept-Encoding = "deflate";
			} else {
				remove req.http.Accept-Encoding;
			}
		}
	}
	
	# File type that we will always cache
	if (req.request == "GET" && req.url ~ "\.(gif|jpg|swf|css|js|png|jpg|jpeg|gif|png|tiff|tif|svg|swf|ico|css|js|vsd|doc|ppt|pps|xls|pdf|mp3|mp4|m4a|ogg|mov|avi|wmv|sxw|zip|gz|bz2|tgz|tar|rar|odc|odb|odf|odg|odi|odp|ods|odt|sxc|sxd|sxi|sxw|dmg|torrent|deb|msi|iso|rpm)$") {
		return(lookup);
	}


	# logged in users must always pass
	# Removed req.http.Cookie ~ "wordpress_logged_in_"
	if(req.url ~ "\?esi$") {
	} else if( req.url ~ "^/[^?]+/wp-(login|admin)" || req.url ~ "^/wp-(login|admin)" || req.url ~ "preview=true") {
		return (pass);
	}

	# Resize images
	if( req.url ~ "\.png\?s=60" ){
	}
	elsif( req.url ~ "\?s="){
		# don't cache search results
		return (pass);
	}

	# always pass through posted requests and those with basic auth
	if ( req.request == "POST" || req.http.Authorization ) {
		return (pass);
	}

	# else ok to fetch a cached page
	unset req.http.Cookie;
	return (lookup); 
}


sub vcl_fetch {

	# Serve items up to half an hour past their expire time
	set beresp.grace = 30m;
	set beresp.ttl = 48h;
	
	# cache ESI requests for 5 minutes
	if (req.url ~ "\?esi$") {
		set beresp.ttl = 5m;
	}
  
	# Enable ESI mode in varnish based on backend responce headers
	if (beresp.http.esi-enabled == "1") {
		set beresp.do_esi = true;
	#unset beresp.http.esi-enabled;
	}
    
	# You are respecting the Cache-Control=private header from the backend
	if (beresp.http.Cache-Control ~ "private") {
		set beresp.http.X-Cacheable = "NO:Cache-Control=private";
    
	# You are extending the lifetime of the object artificially
	} elsif (beresp.ttl < 1s) {
		set beresp.ttl   = 5s;
		set beresp.grace = 5s;
		set beresp.http.X-Cacheable = "YES:FORCED";
    
	# Varnish determined the object was cacheable
	} else {
		set beresp.http.X-Cacheable = "YES";
	}
        
       
	# don't cache response to posted requests or those with basic auth
	if ( req.request == "POST" || req.http.Authorization ) {
		return (hit_for_pass);
	}

        
	# cache 404s and 301s for 1 minute
	if (beresp.status == 404 || beresp.status == 500 || beresp.status == 301 || beresp.status == 302) {
		set beresp.ttl = 1m;
		return (deliver);
	}
      
	# any other request except 200
	if ( beresp.status != 200) {
		return (hit_for_pass);
	}

	# else ok to cache the response
	#set beresp.http.X-expires = beresp.ttl;
	return (deliver);
} 


sub vcl_deliver {

	# add debugging headers, so we can see what's cached
	if (obj.hits > 0) {
		set resp.http.X-Cache = "HIT";
	}
	else {
		set resp.http.X-Cache = "MISS";
	}
	
}

sub vcl_hash {

	# convert request in hash for cache lookup
	hash_data(req.url);
	
}



sub vcl_error {
	# retry connecting to apache 3 times before giving up
	if (obj.status == 503 && req.restarts < 2) {
		set obj.http.X-Restarts = req.restarts;
		return(restart);
	}
	if (obj.status == 301) {
		set obj.http.Location = req.url;
		set obj.status = 301;
		return(deliver);
	}
}
sub vcl_hit {
  if (req.request == "PURGE") {
    error 200 "OK";
  }
}

sub vcl_miss {
  if (req.request == "PURGE") {
    error 404 "Not cached";
  }
}
