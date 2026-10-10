# Prerequisites for ics-import.pl  (multi-event ICS -> CalDAV importer)
#
# Install everything with:
#     cpanm --installdeps .
#
# On Termux first:  pkg install perl make clang
# (see "TERMUX INSTALL" in the script's POD)

# Perl 5.14+: HTTP::Tiny and JSON::PP are core from Perl 5.14
requires 'perl', '5.014';

# --- the real, non-core dependencies ---------------------------------------
# Net::CalDAVTalk does the CalDAV protocol work: RFC 6764 endpoint
# discovery, calendar listing, event PUT (NewEvent), REPORT queries, and
# ICS <-> JSCalendar parsing (via its dependencies Net::DAVTalk,
# Text::JSCalendar, ...). 0.18 is needed for the
# NewEvent/GetEventLinks/vcalendarToEvents API used by the script.
requires 'Net::CalDAVTalk', '0.18';

# YAML::Tiny parses the config file (url / user / password / calendar).
# Tiny and pure-Perl, so it installs quickly even on Termux.
requires 'YAML::Tiny', '1.50';

# --- used directly by the 'list' command -----------------------------------
# (also pulled in transitively by Net::CalDAVTalk, but we call it directly)
requires 'DateTime', '0';

# --- dual-life / core modules the script uses directly ----------------------
# (all core since Perl 5.14; listed so plain Perl installs and old perls
#  resolve them too)
requires 'Getopt::Long', '0';     # command line parsing
requires 'Pod::Usage',   '0';     # --help / --man output
requires 'File::Basename', '0';   # uid extraction from hrefs
requires 'File::Path',    '2.07'; # make_path for 'init'
requires 'File::Spec',    '0';
requires 'File::Temp',    '0';    # temp dir for PDF page images
requires 'HTTP::Tiny',    '0';    # z.ai API calls + webcal/http ICS fetch
requires 'JSON::PP',      '0';    # config file + z.ai request/response JSON
requires 'MIME::Base64',  '0';    # image data-URLs for the z.ai API

# NOTE (not expressible in a cpanfile): PDF support for the 'photo' command
# needs the external poppler tool `pdftoppm`:
#     Termux: pkg install poppler   Debian: apt install poppler-utils
