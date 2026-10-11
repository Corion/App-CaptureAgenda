# This file is run on deployment to create the compressed assets

ASSETS := $(wildcard *.js *.css *.html js/*.js css/*.css)
ZIPPEDASSETS := $(addsuffix .gz,$(ASSETS))

.PHONY: deploy

%.gz: %
	gzip -fk9 $<

#manifest.json: $(ASSETS)
#	PERLLIB= $(PERL) -w ../bump-manifest-version.pl -f --service-worker=sw.js

deploy: $(ZIPPEDASSETS)
