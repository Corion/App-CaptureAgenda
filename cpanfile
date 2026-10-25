# Prerequisites for ics-import.pl  (multi-event ICS -> CalDAV importer)
#
# Install everything with:
#     cpanm --installdeps .
#
# On Termux first:  pkg install perl make clang
# (see "TERMUX INSTALL" in the script's POD)

requires 'perl', '5.020';

# --- the real, non-core dependencies ---------------------------------------
requires 'Text::JSCalendar', '0.08';
requires 'Net::CalDAVTalk', '0.18';
requires 'YAML::Tiny', '1.50';

requires 'DateTime', '0';

requires 'Getopt::Long', '0';     # command line parsing
requires 'Pod::Usage',   '0';     # --help / --man output
requires 'File::Basename', '0';   # uid extraction from hrefs
requires 'File::Path',    '2.07'; # make_path for 'init'
requires 'File::Spec',    '0';
requires 'File::Temp',    '0';    # temp dir for PDF page images
requires 'HTTP::Tiny',    '0';    # z.ai API calls + webcal/http ICS fetch
requires 'JSON::PP',      '0';    # config file + z.ai request/response JSON
requires 'MIME::Base64',  '0';    # image data-URLs for the z.ai API
requires 'PerlX::Maybe',  '0';    # syntax sugar for optional arguments

# NOTE (not expressible in a cpanfile): PDF support for the 'photo' command
# needs the external poppler tool `pdftoppm`:
#     Termux: pkg install poppler   Debian: apt install poppler-utils
