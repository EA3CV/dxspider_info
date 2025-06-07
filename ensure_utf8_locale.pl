#!/usr/bin/perl

#
#  ensure_utf8_locale.pl — Ensure system locale uses UTF-8 encoding
#
#  DXSpider Context:
#    Designed for use in DXSpider-based systems where UTF-8 is required
#    for consistent encoding across user interfaces, logs, filters, DB
#    and external integrations.
#
#  Description:
#    Detects the current Linux distribution and ensures the active locale
#    uses UTF-8 encoding without changing the user’s language settings.
#    If UTF-8 is not enabled, it automatically reconfigures the system
#    locale to use the same language with UTF-8.
#
#  Usage:
#    ensure_utf8_locale.pl
#    Example:
#      sudo ./ensure_utf8_locale.pl
#
#  Installation:
#    Save as: /home/sysop/ensure_utf8_locale.pl
#    Make executable: chmod +x ensure_utf8_locale.pl
#
#  Requirements:
#    - Perl 5
#    - Must be run as root (for system-wide changes)
#    - Works with:
#        - Debian / Ubuntu / Mint / Raspbian
#        - CentOS / Fedora / Rocky Linux / RHEL
#
#  Behavior:
#    - Respects current language (e.g. es_ES, en_EN, fr_FR, ...)
#    - Only enforces UTF-8 if not already active
#    - Skips silently if system already uses UTF-8
#
# 20250607 v0.1
#

# --- Detect distribution from /etc/os-release ---
my %os_release;
if (open my $fh, '<', '/etc/os-release') {
    while (<$fh>) {
        chomp;
        if (/^(\w+)=(.*)$/) {
            my ($k, $v) = ($1, $2);
            $v =~ s/^"//;
            $v =~ s/"$//;
            $os_release{$k} = $v;
        }
    }
    close $fh;
} else {
    die "[ERROR] Could not read /etc/os-release\n";
}

my $id = lc($os_release{ID} // '');
my $version = $os_release{VERSION_ID} // '';
print "[INFO] Detected distribution: $id-$version\n";

# --- Get current LANG value ---
my $lang = $ENV{LANG} || `locale | grep '^LANG='`;
$lang =~ s/^LANG=//;
$lang =~ s/[\s\n]//g;

# Use fallback if LANG is undefined
$lang = 'C.UTF-8' unless $lang;

# --- Extract base locale (e.g., es_ES, fr_FR) ---
my $base_lang = $lang;
$base_lang =~ s/\..*//;

# Desired locale in UTF-8
my $utf8_locale = "$base_lang.UTF-8";

# --- If system is already using UTF-8, skip ---
if ($lang =~ /\.UTF-8$/i) {
    print "[OK] UTF-8 is already configured: $lang\n";
    exit 0;
}

print "[INFO] Will set locale to: $utf8_locale\n";

# --- Run system commands with logging and error check ---
sub run {
    my ($cmd) = @_;
    print "[CMD] $cmd\n";
    system($cmd) == 0 or die "[ERROR] Command failed: $cmd\n";
}

# --- Debian-based systems ---
if ($id =~ /^(debian|ubuntu|linuxmint|raspbian)$/) {
    run('apt update -qq');
    run('apt install -y locales');
    run("sed -i 's/^# *$utf8_locale/$utf8_locale/' /etc/locale.gen || echo '$utf8_locale UTF-8' >> /etc/locale.gen");

    # Compatibilidad con Debian 12 (sin locale-gen)
    run("mkdir -p /usr/lib/locale/$utf8_locale");
    run("localedef -i $base_lang -f UTF-8 $utf8_locale");

    run("bash -c 'echo LANG=$utf8_locale > /etc/default/locale'");
    run("update-locale LANG=$utf8_locale");

# --- RHEL-based systems ---
} elsif ($id =~ /^(centos|rhel|rocky|fedora)$/) {
    run("localectl set-locale LANG=$utf8_locale");
    run("bash -c 'echo LANG=$utf8_locale > /etc/locale.conf'");

# --- Unknown distributions ---
} else {
    print "[WARN] Unknown distribution: $id. Please configure UTF-8 manually.\n";
    exit 1;
}

print "[DONE] UTF-8 locale configured successfully: $utf8_locale\n";
