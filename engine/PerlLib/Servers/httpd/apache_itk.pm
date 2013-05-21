#!/usr/bin/perl

=head1 NAME

 Servers::httpd::apache_itk - i-MSCP Apache ITK Server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2013 by internet Multi Server Control Panel
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# @category    i-MSCP
# @copyright   2010-2013 by i-MSCP | http://i-mscp.net
# @author      Daniel Andreca <sci2tech@gmail.com>
# @author      Laurent Declercq <l;declercq@nuxwin.com>
# @link        http://i-mscp.net i-MSCP Home Site
# @license     http://www.gnu.org/licenses/gpl-2.0.html GPL v2

package Servers::httpd::apache_itk;

use strict;
use warnings;

use iMSCP::Debug;
use iMSCP::HooksManager;
use iMSCP::Config;
use iMSCP::Execute;
use iMSCP::Templator;
use iMSCP::File;
use iMSCP::Dir;
use iMSCP::Ext2Attributes qw(setImmutable clearImmutable isImmutable);
use iMSCP::Rights;
use File::Temp;
use File::Basename;
use POSIX;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Apache ITK Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupHooks($hooksManager)

 Register setup hooks.

 Param iMSCP::HooksManager $hooksManager Hooks manager instance
 Return int 0 on success, other on failure

=cut

sub registerSetupHooks
{
	my $self = shift;
	my $hooksManager = shift;

	require Servers::httpd::apache_itk::installer;
	Servers::httpd::apache_itk::installer->getInstance(
		apacheConfig => \%self::apacheConfig
	)->registerSetupHooks($hooksManager);
}

=item preinstall()

 Process preinstall tasks.

 Return int 0 on success, other on failure

=cut

sub preinstall
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdPreInstall', 'apache_itk');
	return $rs if $rs;

	$rs = $self->stop();
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdPreInstall', 'apache_itk');
}

=item install()

 Process install tasks.

 Return int 0 on success, other on failure

=cut

sub install
{
	my $self = shift;

	require Servers::httpd::apache_itk::installer;
	Servers::httpd::apache_itk::installer->getInstance(apacheConfig => \%self::apacheConfig)->install();
}

=item postinstall()

 Process postinstall tasks.

 Return int 0 on success, other on failure

=cut

sub postinstall
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdPostInstall', 'apache_itk');
	return $rs if $rs;

	$self->{'start'} = 'yes';

	$self->{'hooksManager'}->trigger('afterHttpdPostInstall', 'apache_itk');
}

=item uninstall()

 Process uninstall tasks.

 Return int 0 on success, other on failure

=cut

sub uninstall
{
	my $self = shift;

	my $rs = $self->stop();
	return $rs if $rs;

	$rs = $self->{'hooksManager'}->trigger('beforeHttpdUninstall', 'apache_itk');
	return $rs if $rs;

	require Servers::httpd::apache_itk::uninstaller;
	$rs = Servers::httpd::apache_itk::uninstaller->getInstance()->uninstall();
	return $rs if $rs;

	$rs = $self->{'hooksManager'}->trigger('afterHttpdUninstall', 'apache_itk');
	return $rs if $rs;

	$self->start();
}

=item addUser(\%data)

 Process addUser tasks.

 Param hash_ref $data Reference to a hash containing data as provided by User module
 Return int 0 on success, other on failure

=cut

sub addUser($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	$self->{'data'} = $data;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddUser', $data);
	return $rs if $rs;

	# START MOD CBAND SECTION

	$rs = iMSCP::File->new(
		'filename' => "$self->{'wrkDir'}/00_modcband.conf"
	)->copyFile(
		"$self->{'bkpDir'}/00_modcband.conf." . time
	) if (-f "$self->{'wrkDir'}/00_modcband.conf");
	return $rs if $rs;

	my $filename = (
		-f "$self->{'wrkDir'}/00_modcband.conf"
			? "$self->{'wrkDir'}/00_modcband.conf" : "$self->{'cfgDir'}/00_modcband.conf"
	);

	my $file = iMSCP::File->new('filename' => $filename);
	my $content = $file->get();

	unless(defined $content) {
		error("Unable to read $filename");
		return $rs if $rs;
	} else {
		my $bTag = "## SECTION {USER} BEGIN.\n";
		my $eTag = "## SECTION {USER} END.\n";
		my $bUTag = "## SECTION $data->{'USER'} BEGIN.\n";
		my $eUTag = "## SECTION $data->{'USER'} END.\n";

		my $entry = getBloc($bTag, $eTag, $content);
		$entry =~ s/#//g;

		$content = replaceBloc($bUTag, $eUTag, '', $content);

		$self->{'data'}->{'BWLIMIT_DISABLED'} = ($data->{'BWLIMIT'} ? '' : '#');

		$entry = $self->buildConf("    $bTag$entry    $eTag");
		$content = replaceBloc($bTag, $eTag, $entry, $content, 'preserve');

		$file = iMSCP::File->new('filename' => "$self->{'wrkDir'}/00_modcband.conf");
		$rs = $file->set($content);
		return $rs if $rs;

		$rs = $file->save();
		return $rs if $rs;

		$rs = $self->installConfFile('00_modcband.conf');
		return $rs if $rs;

		$rs = $self->enableSite('00_modcband.conf');
		return $rs if $rs;

		if($data->{'BWLIMIT'}) {
			unless( -f "$self::apacheConfig{'SCOREBOARDS_DIR'}/$data->{'USER'}") {
				$rs = iMSCP::File->new('filename' => "$self::apacheConfig{'SCOREBOARDS_DIR'}/$data->{'USER'}")->save();
				return $rs if $rs;
			}
		} elsif(-f "$self::apacheConfig{'SCOREBOARDS_DIR'}/$data->{'USER'}") {
			$rs = iMSCP::File->new('filename' => "$self::apacheConfig{'SCOREBOARDS_DIR'}/$data->{'USER'}")->delFile();
			return $rs if $rs;
		}
	}

	# END MOD CBAND SECTION

	# Adding Apache user into i-MSCP virtual user group
	my $apacheUName = iMSCP::SystemUser->new('username' => $self->getRunningUser());
	$rs = $apacheUName->addToGroup($data->{'GROUP'});
	return $rs if $rs;

	$self->{'restart'} = 'yes';

	$self->{'hooksManager'}->trigger('afterHttpdAddUser', $data);
}

=item delUser(\%data)

 Process delUser tasks.

 Param hash_ref $data Reference to a hash containing data as provided by User module
 Return int 0 on success, other on failure

=cut

sub delUser($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	$self->{'data'} = $data;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelUser', $data);
	return $rs if $rs;

	# START MOD CBAND SECTION

	$rs = iMSCP::File->new(
		'filename' => "$self->{'wrkDir'}/00_modcband.conf"
	)->copyFile(
		"$self->{'bkpDir'}/00_modcband.conf." . time
	) if -f "$self->{'wrkDir'}/00_modcband.conf";
	return $rs if $rs;

	my $filename = (
		-f "$self->{'wrkDir'}/00_modcband.conf"
			? "$self->{'wrkDir'}/00_modcband.conf" : "$self->{'cfgDir'}/00_modcband.conf"
	);

	my $file = iMSCP::File->new('filename' => $filename);
	my $content = $file->get();

	unless(defined $content) {
		error("Unable to read $filename");
		return $rs if $rs;
	} else {
		my $bUTag = "## SECTION $data->{'USER'} BEGIN.\n";
		my $eUTag = "## SECTION $data->{'USER'} END.\n";

		$content = replaceBloc($bUTag, $eUTag, '', $content);

		$file = iMSCP::File->new('filename' => "$self->{'wrkDir'}/00_modcband.conf");
		$rs = $file->set($content);
		return $rs if $rs;

		$rs = $file->save();
		return $rs if $rs;

		$rs = $self->installConfFile('00_modcband.conf');
		return $rs if $rs;

		$rs = $self->enableSite('00_modcband.conf');
		return $rs if $rs;

		if( -f "$self::apacheConfig{'SCOREBOARDS_DIR'}/$data->{'USER'}") {
			$rs = iMSCP::File->new('filename' => "$self::apacheConfig{'SCOREBOARDS_DIR'}/$data->{'USER'}")->delFile();
			return $rs if $rs;
		}
	}

	# END MOD CBAND SECTION

	# Removing Apache user from i-MSCP virtual user group
	my $apacheUName = iMSCP::SystemUser->new('username' => $self->getRunningUser());
	$rs = $apacheUName->removeFromGroup($data->{'GROUP'});
	return $rs if $rs;

	$self->{'restart'} = 'yes';

	$self->{'hooksManager'}->trigger('afterHttpdDelUser', $data);
}

=item addDmn(\%data)

 Process addDmn tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Alias|Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub addDmn($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddDmn', $data);
	return $rs if $rs;

	$self->{'data'} = $data;

	$rs = $self->_addCfg($data);
	return $rs if $rs;

	$rs = $self->_addFiles($data) if $data->{'FORWARD'} eq 'no';
	return $rs if $rs;

	$self->{'restart'} = 'yes';

	delete $self->{'data'};

	$self->{'hooksManager'}->trigger('afterHttpdAddDmn', $data);
}

=item restoreDmn

 Process restoreDmn tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Alias|Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub restoreDmn($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	$self->{'data'} = $data;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdRestoreDmn', $data);
	return $rs if $rs;

	$rs = $self->_addFiles($data) if $data->{'FORWARD'} eq 'no';
	return $rs if $rs;

	delete $self->{'data'};

	$self->{'hooksManager'}->trigger('afterHttpdRestoreDmn', $data);
}

=item disableDmn(\%data)

 Process disableDmn tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Alias|Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub disableDmn($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	$self->{'data'} = $data;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDisableDmn', $data);
	return $rs if $rs;

	iMSCP::File->new(
		'filename' => "$self->{'wrkDir'}/$data->{'DOMAIN_NAME'}.conf"
	)->copyFile(
		"$self->{'bkpDir'}/$data->{'DOMAIN_NAME'}.conf". time
	) if -f "$self->{'wrkDir'}/$data->{'DOMAIN_NAME'}.conf";
	return $rs if $rs;

	$rs = $self->buildConfFile(
		"$self->{'tplDir'}/domain_disabled.tpl",
		{ 'destination' => "$self->{'wrkDir'}/$data->{'DOMAIN_NAME'}.conf" }
	);
	return $rs if $rs;

	$rs = $self->installConfFile("$data->{'DOMAIN_NAME'}.conf");
	return $rs if $rs;

	$rs = $self->enableSite("$data->{'DOMAIN_NAME'}.conf");
	return $rs if $rs;

	$self->{'restart'} = 'yes';

	delete $self->{'data'};

	$self->{'hooksManager'}->trigger('afterHttpdDisableDmn', $data);
}

=item delDmn(\%data)

 Process delDmn tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Alias|Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub delDmn($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelDmn', $data);
	return $rs if $rs;

	# Disable apache site files
	for("$data->{'DOMAIN_NAME'}.conf", "$data->{'DOMAIN_NAME'}_ssl.conf") {
		$rs = $self->disableSite($_) if -f "$self::apacheConfig{'APACHE_SITES_DIR'}/$_";
		return $rs if $rs;
	}

	# Remove apache site files
	for(
		"$self::apacheConfig{'APACHE_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf",
		"$self::apacheConfig{'APACHE_SITES_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf",
		"$self::apacheConfig{'APACHE_CUSTOM_SITES_CONFIG_DIR'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'wrkDir'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'wrkDir'}/$data->{'DOMAIN_NAME'}_ssl.conf",
	) {
		$rs = iMSCP::File->new('filename' => $_)->delFile() if -f $_;
		return $rs if $rs;
	}

	# Remove Web directory if needed

	my $webDir = $data->{'WEB_DIR'};

	if(-d $webDir) {
		if($data->{'DOMAIN_TYPE'} eq 'dmn') {
			# Unprotect Web root directory
			clearImmutable($webDir);

			$rs = iMSCP::Dir->new('dirname' => $webDir)->remove();
			return $rs if $rs;
		} else {
			my @sharedMountPoints = @{$data->{'SHARED_MOUNT_POINTS'}};

			# Normalize all mount points to match against
			s%(/.*?)/+$%$1% for @sharedMountPoints;

			# Normalize mount point
			(my $mountPoint = $data->{'MOUNT_POINT'}) =~ s%(/.*?)/+$%$1%;

			# We process only if we doesn't have other entity sharing identical mount point
			if($mountPoint ne '/' && not $mountPoint ~~ @sharedMountPoints) {

				# Unprotect Web root directory
				clearImmutable($webDir);

				my $skelDir = $data->{'DOMAIN_TYPE'} eq 'als'
					? "$self->{'cfgDir'}/skel/domain" : "$self->{'cfgDir'}/skel/subdomain";

				for(iMSCP::Dir->new('dirname' => $skelDir)->getAll()) {
					if(-d "$webDir/$_") {
						$rs = iMSCP::Dir->new('dirname' => "$webDir/$_")->remove();
						return $rs if $rs;
					} elsif(-f _) {
						$rs = iMSCP::File->new('filename' => "$webDir/$_")->delFile();
						return $rs if $rs;
					}
				}

				(my $mountPointRootDir = $mountPoint) =~ s%^(/[^/]+).*%$1%;
				$mountPointRootDir = dirname("$data->{'WWW_DIR'}/$data->{'ROOT_DOMAIN_NAME'}$mountPointRootDir");
				my $dirToRemove = $webDir;
				my $dirToRemoveParentDir;
				my $isProtectedDirToRemoveParentDir = 0;
				my $dirHandler = iMSCP::Dir->new();

				# Here, we loop over all directories, which are part of the mount point of the Web folder to remove.
				# In case a directory is not empty, we do not remove it since:
				# - Unknown directories/files are never removed (responsability is left to user)
				# - A directory can be the root directory of another mount point
				while($dirToRemove ne $mountPointRootDir && $dirHandler->isEmpty($dirToRemove)) {

					$dirToRemoveParentDir = dirname($dirToRemove);

					if(isImmutable($dirToRemoveParentDir)) {
						$isProtectedDirToRemoveParentDir = 1;
						clearImmutable($dirToRemoveParentDir);
					}

					clearImmutable($dirToRemove);

					$rs = $dirHandler->remove();
					return $rs if $rs;

					setImmutable($dirToRemoveParentDir) if $isProtectedDirToRemoveParentDir;

					$dirToRemove = $dirToRemoveParentDir;
				}
			}
		}
	}

	$self->{'restart'} = 'yes';

	delete $self->{'data'};

	$self->{'hooksManager'}->trigger('afterHttpdDelDmn', $data);
}

=item addSub(\%data)

 Process addSub tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub addSub($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	$self->{'data'} = $data;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddSub', $data);
	return $rs if $rs;

	$rs = $self->_addCfg($data);
	return $rs if $rs;

	$rs = $self->_addFiles($data) if $data->{'FORWARD'} eq 'no';
	return $rs if $rs;

	$self->{'restart'} = 'yes';

	delete $self->{'data'};

	$self->{'hooksManager'}->trigger('afterHttpdAddSub', $data);
}

=item restoreSub($\data)

 Process restoreSub tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub restoreSub($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	$self->{'data'} = $data;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdRestoreSub', $data);
	return $rs if $rs;

	$rs = $self->_addFiles($data) if $data->{'FORWARD'} eq 'no';
	return $rs if $rs;

	delete $self->{'data'};

	$self->{'hooksManager'}->trigger('afterHttpdRestoreSub', $data);

	0;
}

=item disableSub(\$data)

 Process disableSub tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub disableSub($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDisableSub', $data);
	return $rs if $rs;

	$rs = $self->disableDmn($data);
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdDisableSub', $data);
}

=item delSub(\%data)

 Process delSub tasks.

 Param hash_ref $data Reference to a hash containing data as provided by the module Subdomain|SubAlias
 Return int 0 on success, other on failure

=cut

sub delSub($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelSub', $data);

	$rs = $self->delDmn($data);
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdDelSub', $data);
}

=item AddHtuser(\%data)

 Process AddHtuser tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Htuser module
 Return int 0 on success, other on failure

=cut

sub addHtuser($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self::apacheConfig{'HTACCESS_USERS_FILE_NAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new('filename' => $filePath);
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddHtuser', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTUSER_NAME'}:[^\n]*\n//gim;
	$fileContent .= "$data->{'HTUSER_NAME'}:$data->{'HTUSER_PASS'}\n";

	$rs = $self->{'hooksManager'}->trigger('afterHttpdAddHtuser', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->set($fileContent);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item delHtuser(\%data)

 Process delHtuser tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Htuser module
 Return int 0 on success, other on failure

=cut

sub delHtuser($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self::apacheConfig{'HTACCESS_USERS_FILE_NAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new('filename' => $filePath);
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelHtuser', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTUSER_NAME'}:[^\n]*\n//gim;

	$rs = $self->{'hooksManager'}->trigger('afterHttpdDelHtuser', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->set($fileContent);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item addHtgroup(\%data)

 Process addHtgroup tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Htgroup module
 Return int 0 on success, other on failure

=cut

sub addHtgroup($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self::apacheConfig{'HTACCESS_GROUPS_FILE_NAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new('filename' => $filePath);
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTGROUP_NAME'}:[^\n]*\n//gim;
	$fileContent .= "$data->{'HTGROUP_NAME'}:$data->{'HTGROUP_USERS'}\n";

	$rs = $self->{'hooksManager'}->trigger('afterHttpdAddHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->set($fileContent);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item delHtgroup(\%data)

 Process delHtgroup tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Htgroup module
 Return int 0 on success, other on failure

=cu

sub delHtgroup($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self::apacheConfig{'HTACCESS_GROUPS_FILE_NAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new('filename' => $filePath);
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTGROUP_NAME'}:[^\n]*\n//gim;

	$rs = set($fileContent);
	return $rs if $rs;

	$rs = $self->{'hooksManager'}->trigger('afterHttpdDelHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item addHtaccess(\%data)

 Process addHtaccess tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Htaccess module
 Return int 0 on success, other on failure

=cut

sub addHtaccess($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	# Here we process only if AUTH_PATH directory exists
	# Note: It's temporary fix for 1.1.0-rc2 (See #749)
	if(-d $data->{'AUTH_PATH'}) {
		my $fileUser = "$data->{'HOME_PATH'}/$self::apacheConfig{'HTACCESS_USERS_FILE_NAME'}";
		my $fileGroup = "$data->'{HOME_PATH'}/$self::apacheConfig{'HTACCESS_GROUPS_FILE_NAME'}";
		my $filePath = "$data->{'AUTH_PATH'}/.htaccess";

		my $file = iMSCP::File->new('filename' => $filePath);
		my $fileContent = $file->get() if -f $filePath;
		$fileContent = '' unless defined $fileContent;

		my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddHtaccess', \$fileContent, $data);
		return $rs if $rs;

		my $bTag = "### START i-MSCP PROTECTION ###\n";
		my $eTag = "### END i-MSCP PROTECTION ###\n";
		my $tagContent = "AuthType $data->{'AUTH_TYPE'}\nAuthName \"$data->{'AUTH_NAME'}\"\nAuthUserFile $fileUser\n";

		if($data->{'HTUSERS'} eq '') {
			$tagContent .= "AuthGroupFile $fileGroup\nRequire group $data->{'HTGROUPS'}\n";
		} else {
			$tagContent .= "Require user $data->{'HTUSERS'}\n";
		}

		$fileContent = replaceBloc($bTag, $eTag, '', $fileContent);
		$fileContent = $bTag . $tagContent . $eTag . $fileContent;

		$rs = $self->{'hooksManager'}->trigger('afterHttpdAddHtaccess', \$fileContent, $data);
		return $rs if $rs;

		$rs = $file->set($fileContent);
		return $rs if $rs;

		$rs = $file->save();
		return $rs if $rs;

		$rs = $file->mode(0640);
		return $rs if $rs;

		$file->owner($data->{'USER'}, $data->{'GROUP'});
	} else {
		0;
	}
}

=item delHtaccess(\%data)

 Process delHtaccess tasks.

 Param hash_ref $data Reference to a hash containing data as provided by Htaccess module
 Return int 0 on success, other on failure

=cut

sub delHtaccess($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	# Here we process only if AUTH_PATH directory exists
	# Note: It's temporary fix for 1.1.0-rc2 (See #749)
	if(-d $data->{'AUTH_PATH'}) {
		my $fileUser = "$data->{'HOME_PATH'}/$self::apacheConfig{'HTACCESS_USERS_FILE_NAME'}";
		my $fileGroup = "$data->'{HOME_PATH'}/$self::apacheConfig{'HTACCESS_GROUPS_FILE_NAME'}";
		my $filePath = "$data->{'AUTH_PATH'}/.htaccess";

		my $file = iMSCP::File->new('filename' => $filePath);
		my $fileContent = $file->get() if -f $filePath;
		$fileContent = '' unless defined $fileContent;

		my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelHtaccess', \$fileContent, $data);
		return $rs if $rs;

		my $bTag = "### START i-MSCP PROTECTION ###\n";
		my $eTag = "### END i-MSCP PROTECTION ###\n";

		$fileContent = replaceBloc($bTag, $eTag, '', $fileContent);

		$rs = $self->{'hooksManager'}->trigger('afterHttpdDelHtaccess', \$fileContent, $data);
		return $rs if $rs;

		if($fileContent ne '') {
			$rs = $file->set($fileContent);
			return $rs if $rs;

			$rs = $file->save();
			return $rs if $rs;

			$rs = $file->mode(0640);
			return $rs if $rs;

			$rs = $file->owner($data->{'USER'}, $data->{'GROUP'});
			return $rs if $rs;
		} else {
			$rs = $file->delFile() if -f $filePath;
			return $rs if $rs;
		}
	}

	0;
}

=item addIps(\%data)

 Process addIps tasks..

 Param hash_ref $data Reference to a hash containing data as provided by Ips module
 Return int 0 on success, other on failure

=cut

sub addIps($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $wrkFile = "$self->{'wrkDir'}/00_nameserver.conf";

	# Backup current working file if any
	my $rs = iMSCP::File->new(
		'filename' => $wrkFile
	)->copyFile(
		"$self->{'bkpDir'}/00_nameserver.conf.". time
	) if -f $wrkFile;
	return $rs if $rs;

	my $wrkFileH = iMSCP::File->new('filename' => $wrkFile);

	my $content = $wrkFileH->get();
	unless(defined $content) {
		error("Unable to read $wrkFile");
		return 1;
	}

	$rs = $self->{'hooksManager'}->trigger('beforeHttpdAddIps', \$content, $data);
	return $rs if $rs;

	$content =~ s/NameVirtualHost[^\n]+\n//gi;

	$content.= "NameVirtualHost $_:443\n" for @{$data->{'SSLIPS'}};
	$content.= "NameVirtualHost $_:80\n" for @{$data->{'IPS'}};

	$rs = $self->{'hooksManager'}->trigger('afterHttpdAddIps', \$content, $data);
	return $rs if $rs;

	$rs = $wrkFileH->set($content);
	return $rs if $rs;

	$rs = $wrkFileH->save();
	return $rs if $rs;

	$rs = $self->installConfFile('00_nameserver.conf');
	return $rs if $rs;

	$rs = $self->enableSite('00_nameserver.conf');
	return $rs if $rs;

	$self->{'restart'} = 'yes';

	delete $self->{'data'};

	0;
}

=item setGuiPermissions()

 Set gui permissions.

 Return int 0 on success, other on failure

=cut

sub setGuiPermissions
{
	my $self = shift;

	require Servers::httpd::apache_itk::installer;
	Servers::httpd::apache_itk::installer->getInstance(apacheConfig => \%self::apacheConfig)->setGuiPermissions();
}

=item setEnginePermissions()

 Set engine permissions.

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
	my $self = shift;

	require Servers::httpd::apache_itk::installer;
	Servers::httpd::apache_itk::installer->getInstance(apacheConfig => \%self::apacheConfig)->setEnginePermissions();
}

=item buildConf($cfgTpl, $filename)

 Build the given configuration template.

 Param string $cfgTpl String representing content of the configuration template
 Param string $filename Configuration template name
 Return string String representing content of configuration template or undef

=cut

sub buildConf($$$)
{
	my $self = shift;
	my $cfgTpl = shift;
	my $filename = shift;

	unless(defined $cfgTpl) {
		error('Empty configuration template...');
		return undef;
	}

	$self->{'tplValues'}->{$_} = $self->{'data'}->{$_} for keys %{$self->{'data'}};

	$self->{'hooksManager'}->trigger('beforeHttpdBuildConf', \$cfgTpl, $filename);

	$cfgTpl = process($self->{'tplValues'}, $cfgTpl);
	return undef if ! $cfgTpl;

	$self->{'hooksManager'}->trigger('afterHttpdBuildConf', \$cfgTpl, $filename);

	$cfgTpl;
}

=item buildConfFile($file, [\%options = {}])

 Build the given configuration file.

 Param string $file Absolute path to config file or config filename relative to the $self->{'apacheCfgDir'} directory
 Param hash_ref $options Reference to a hash containing options such as destination, mode, user and group for final file
 Return int 0 on success, other on failure

=cut

sub buildConfFile($$;$)
{
	my $self = shift;
	my $file = shift;
	my $options = shift || {};

	fatal('Hash reference expected') if ref $options ne 'HASH';

	my ($name, $path, $suffix) = fileparse($file);

	$file = "$self->{'cfgDir'}/$file" unless -d $path && $path ne './';

	my $fileH = iMSCP::File->new('filename' => $file);
	my $cfgTpl = $fileH->get();
	unless(defined $cfgTpl) {
		error("Unable to read $file");
		return 1;
	}

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdBuildConfFile', \$cfgTpl, "$name$suffix", $options);
	return $rs if $rs;

	$cfgTpl = $self->buildConf($cfgTpl, "$name$suffix");
	return 1 unless defined $cfgTpl;

	$cfgTpl =~ s/\n{2,}/\n\n/g; # Remove any duplicate blank lines

	$rs = $self->{'hooksManager'}->trigger('afterHttpdBuildConfFile', \$cfgTpl, "$name$suffix", $options);
	return $rs if $rs;

	$fileH = iMSCP::File->new(
		'filename' => ($options->{'destination'} ? $options->{'destination'} : "$self->{'wrkDir'}/$name$suffix")
	);

	$rs = $fileH->set($cfgTpl);
	return $rs if $rs;

	$rs = $fileH->save();
	return $rs if $rs;

	$rs = $fileH->mode($options->{'mode'} ? $options->{'mode'} : 0644);
	return $rs if $rs;

	$fileH->owner(
		$options->{'user'} ? $options->{'user'} : $main::imscpConfig{'ROOT_USER'},
		$options->{'group'} ? $options->{'group'} : $main::imscpConfig{'ROOT_GROUP'}
	);
}

=item installConfFile($file, [\%options = {}])

 Install the given configuration file.

 Param string $file Absolute path to config file or config filename relative to the $self->{'apacheWrkDir'} directory
 Param hash_ref $options Reference to a hash containing options such as destination, mode, user and group for final file
 Return int 0 on success, other on failure

=cut

sub installConfFile($$;$)
{
	my $self = shift;
	my $file = shift;
	my $options = shift || {};

	fatal('Hash reference expected') if ref $options ne 'HASH';

	my ($name, $path, $suffix) = fileparse($file);

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdInstallConfFile', "$name$suffix", $options);
	return $rs if $rs;

	$file = "$self->{'wrkDir'}/$file" unless -d $path && $path ne './';

	my $fileH = iMSCP::File->new('filename' => $file);

	$rs = $fileH->mode($options->{'mode'} ? $options->{'mode'} : 0644);
	return $rs if $rs;

	$rs = $fileH->owner(
		$options->{'user'} ? $options->{'user'} : $main::imscpConfig{'ROOT_USER'},
		$options->{'group'} ? $options->{'group'} : $main::imscpConfig{'ROOT_GROUP'}
	);
	return $rs if $rs;

	$rs = $fileH->copyFile(
		$options->{'destination'} ? $options->{'destination'} : "$self::apacheConfig{'APACHE_SITES_DIR'}/$name$suffix"
	);
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdInstallConfFile', "$name$suffix", $options);
}

=item setData(\%data)

 Make the given data available for this server.

 Param hash_ref $data Reference to a hash containing data to make available for this server.
 Return int 0 on success, other on failure

=cut

sub setData($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdSetData', $data);
	return $rs if $rs;

	$self->{'data'} = $data;

	$self->{'hooksManager'}->trigger('afterHttpdSetData', $data);
}

=item removeSection($sectionName, \$cfgTpl)

 Remove the given section in the given configuration template string.

 Param string $sectionName Name of section to remove
 Param string_ref $cfgTpl Reference to configuration template string
 Return int 0

=cut

sub removeSection($$$)
{
	my $self = shift;
	my $sectionName = shift;
	my $cfgTpl = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdRemoveSection', $sectionName, $cfgTpl);
	return $rs if $rs;

	my $bTag = "# SECTION $sectionName BEGIN.\n";
	my $eTag = "# SECTION $sectionName END.\n";

	debug("Removing useless section: $sectionName");

	$$cfgTpl = replaceBloc($bTag, $eTag, '', $$cfgTpl);

	$self->{'hooksManager'}->trigger('afterHttpdRemoveSection', $sectionName, $cfgTpl);
}

=item getTraffic($who)

 Return traffic consumption for the given domain.

 Param string $who Traffic log owner name
 Return int Traffic in bytes

=cut

sub getTraffic($$)
{
	my $self = shift;
	my $who = shift;

	my $traff = 0;
	my $trfDir = "$self::apacheConfig{'APACHE_LOG_DIR'}/traff";
	my ($rv, $rs, $stdout, $stderr);

	$self->{'hooksManager'}->trigger('beforeHttpdGetTraffic', $who);

	unless($self->{'logDb'}) {
		$self->{'logDb'} = 1;

		$rs = execute("$main::imscpConfig{'CMD_PS'} -o pid,args -C 'imscp-apache-logger'", \$stdout, \$stderr);
		error($stderr) if $stderr && $rs;

		my $rv = iMSCP::Dir->new('dirname' => $trfDir)->moveDir("$trfDir.old") if -d $trfDir;

		if($rv) {
			delete $self->{'logDb'};
			return 0;
		}

		if($rs || ! $stdout) {
			error('imscp-apache-logger is not running') unless $stderr;
		} else {
			while($stdout =~ m/^\s{0,}(\d+)(?!.*error)/gm) {
				$rs = execute("kill -s HUP $1", \$stdout, \$stderr);
				debug($stdout) if $stdout;
				error($stderr) if $stderr && $rs;
			}
		}
	}

	if(-d "$trfDir.old" && -f "$trfDir.old/$who-traf.log") {
		my $content = iMSCP::File->new('filename' => "$trfDir.old/$who-traf.log")->get();

		if($content) {
			my @lines = split("\n", $content);
			$traff += $_ for @lines;
		} else {
			error("Unable to read $trfDir.old/$who-traf.log");
		}
	}

	$self->{'hooksManager'}->trigger('afterHttpdGetTraffic', $who, $traff);

	$traff;
}

=item delOldLogs()

 Remove Apache logs (logs older than 1 year).

 Return int 0 on success, other on failure

=cut

sub delOldLogs
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelOldLogs');
	return $rs if $rs;

	my $logDir = $self::apacheConfig{'APACHE_LOG_DIR'};
	my $backupLogDir = $self::apacheConfig{'APACHE_BACKUP_LOG_DIR'};
	my $usersLogDir = $self::apacheConfig{'APACHE_USERS_LOG_DIR'};
	my ($stdout, $stderr);

	for ($logDir, $backupLogDir, $usersLogDir) {
		my $cmd = "nice -n 19 find $_ -maxdepth 1 -type f -name '*.log*' -mtime +365 -exec rm -v {} \\;";
		$rs = execute($cmd, \$stdout, \$stderr);
		debug($stdout) if $stdout;
		error($stderr) if $stderr && $rs;
		error("Error while executing $cmd.\nReturned value is $rs") if $rs && ! $stderr;
		return $rs if $rs;
	}

	$self->{'hooksManager'}->trigger('afterHttpdDelOldLogs');
}

=item delTmp()

 Delete temporary files (PHP session files).

 Return int 0 on success, other on failure

=cut

sub delTmp
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDelTmp');
	return $rs if $rs;

	my ($stdout, $stderr);

	# panel sessions gc (since we are not using default session path)

	if(-d "/var/www/imscp/gui/data/sessions"){
		my $cmd = '[ -x /usr/lib/php5/maxlifetime ] && [ -d /var/www/imscp/gui/data/sessions ] && find /var/www/imscp/gui/data/sessions/ -type f -cmin +$(/usr/lib/php5/maxlifetime) -delete';
		$rs |= execute($cmd, \$stdout, \$stderr);
		debug($stdout) if $stdout;
		error($stderr) if $stderr && $rs;
		error("Error while executing $cmd.\nReturned value is $rs") if ! $stderr && $rs;
		return $rs if $rs;
	}

	# Note: Customer session files are removed by distro cron task

	$self->{'hooksManager'}->trigger('afterHttpdDelTmp');
}

=item getRunningUser()

 Get user name under which the Apache server is running.

 Return string User name under which the apache server is running.

=cut

sub getRunningUser
{
	my $self = shift;

	$self::apacheConfig{'APACHE_USER'};
}

=item getRunningUser()

 Get group name under which the Apache server is running.

 Return string Group name under which the apache server is running.

=cut

sub getRunningGroup
{
	my $self = shift;

	$self::apacheConfig{'APACHE_GROUP'};
}

=item enableSite($sites)

 Enable the given Apache sites.

 Param string $site Names of Apache sites to enable, each separated by a space
 Return int 0 on sucess, other on failure

=cut

sub enableSite($$)
{
	my $self = shift;
	my $sites = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdEnableSite', \$sites);
	return $rs if $rs;

	my ($stdout, $stderr);

	for(split(' ', $sites)){
		if(-f "$self::apacheConfig{'APACHE_SITES_DIR'}/$_") {
			$rs = execute("a2ensite $_", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			error($stderr) if $stderr && $rs;
			return $rs if $rs;
		} else {
			warning("Site $_ doesn't exists");
		}
	}

	$self->{'hooksManager'}->trigger('afterHttpdEnableSite', $sites);
}

=item disableSite($sites)

 Disable the given Apache sites.

 Param string $sitse Names of Apache sites to disable, each separated by a space
 Return int 0 on sucess, other on failure

=cut

sub disableSite($$)
{
	my $self = shift;
	my $sites = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDisableSite', \$sites);
	return $rs if $rs;

	my ($stdout, $stderr);

	for(split(' ', $sites)) {
		if(-f "$self::apacheConfig{'APACHE_SITES_DIR'}/$_") {
			$rs = execute("a2dissite $_", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			error($stderr) if $stderr && $rs;
			return $rs if $rs;
		} else {
			warning("Site $_ doesn't exists");
		}
	}

	$self->{'hooksManager'}->trigger('afterHttpdDisableSite', $sites);
}

=item enableMod($modules)

 Enable the given Apache modules.

 Param string $modules Names of Apache modules to enable, each separated by a space
 Return int 0 on sucess, other on failure

=cut

sub enableMod($$)
{
	my $self = shift;
	my $modules = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdEnableMod', \$modules);
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute("a2enmod $modules", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $stderr && $rs;
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdEnableMod', $modules);
}

=item disableMod($modules)

 Disable the given Apache modules.

 Param string $modules Names of Apache modules to disable, each separated by a space
 Return int 0 on sucess, other on failure

=cut

sub disableMod($$)
{
	my $self = shift;
	my $modules = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdDisableMod', \$modules);
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute("a2dismod $modules", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $stderr && $rs;
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdDisableMod', $modules);
}

=item forceRestartApache()

 Schedule Apache restart.

 Return int 0

=cut

sub forceRestart
{
	my $self = shift;

	$self->{'forceRestart'} = 'yes';

	0;
}

=item startApache()

 Start Apache.

 Return int 0, other on failure

=cut

sub start
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdStart');
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute("$self->{'tplValues'}->{'CMD_HTTPD'} start", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	warning($stderr) if $stderr && ! $rs;
	error($stderr) if $stderr && $rs;
	error("Error while starting") if $rs && ! $stderr;
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdStart');
}

=item stopApache()

 Stop Apache.

 Return int 0, other on failure

=cut

sub stop
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdStop');
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute("$self->{'tplValues'}->{'CMD_HTTPD'} stop", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	warning($stderr) if $stderr && ! $rs;
	error($stderr) if $stderr && $rs;
	error("Error while stopping") if $rs && ! $stderr;
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdStop');
}

=item restartApache()

 Restart or Reload Apache.

 Return int 0, other on failure

=cut

sub restart
{
	my $self = shift;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdRestart');
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute(
		"$self->{'tplValues'}->{'CMD_HTTPD'} " . ($self->{'forceRestart'} ? 'restart' : 'reload'), \$stdout, \$stderr
	);
	debug($stdout) if $stdout;
	warning($stderr) if $stderr && ! $rs;
	error($stderr) if $stderr && $rs;
	error("Error while restarting") if $rs && ! $stderr;
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdRestart');
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Called by getInstance(). Initialize instance.

 Return Servers::httpd::apache_itk

=cut

sub _init
{
	my $self = shift;

	$self->{'hooksManager'} = iMSCP::HooksManager->getInstance();

	$self->{'hooksManager'}->trigger(
		'beforeHttpdInit', $self, 'apache_itk'
	) and fatal('apache_itk - beforeHttpdInit hook has failed');

	$self->{'cfgDir'} = "$main::imscpConfig{'CONF_DIR'}/apache";
	$self->{'bkpDir'} = "$self->{'cfgDir'}/backup";
	$self->{'wrkDir'} = "$self->{'cfgDir'}/working";
	$self->{'tplDir'} = "$self->{'cfgDir'}/parts";

	my $conf = "$self->{'cfgDir'}/apache.data";
	tie %self::apacheConfig, 'iMSCP::Config','fileName' => $conf;

	$self->{'tplValues'}->{$_} = $self::apacheConfig{$_} for keys %self::apacheConfig;

	$self->{'hooksManager'}->trigger(
		'afterHttpdInit', $self, 'apache_itk'
	) and fatal('apache_itk - afterHttpdInit hook has failed');

	$self;
}

=item _addCfg(\%data)

 Add configuration files for the given domain or subdomain

 Param hash_ref Reference to a hash containing data
 Return int 0 on success, other on failure

=cut

sub _addCfg($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	$self->{'data'} = $data;

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddCfg', $data);
	return $rs if $rs;

	# Disable and backup Apache sites if any
	for("$data->{'DOMAIN_NAME'}.conf", "$data->{'DOMAIN_NAME'}_ssl.conf") {
		$rs = $self->disableSite($_) if -f "$self::apacheConfig{'APACHE_SITES_DIR'}/$_";
		return $rs if $rs;

		$rs = iMSCP::File->new(
			'filename' => "$self::apacheConfig{'APACHE_SITES_DIR'}/$_"
		)->copyFile(
			"$self->{'bkpDir'}/$_." . time
		) if -f "$self::apacheConfig{'APACHE_SITES_DIR'}/$_";
		return $rs if $rs;
	}

	# Remove previous Apache sites if any
	for(
		"$self::apacheConfig{'APACHE_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf",
		"$self::apacheConfig{'APACHE_SITES_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf",
		"$self->{'wrkDir'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'wrkDir'}/$data->{'DOMAIN_NAME'}_ssl.conf"
	) {
		$rs = iMSCP::File->new('filename' => $_)->delFile() if -f $_;
		return $rs if $rs;
	}

	# Build Apache sites - Begin

	my %configs;
	$configs{"$data->{'DOMAIN_NAME'}.conf"} = { 'redirect' => 'domain_redirect.tpl', 'normal' => 'domain.tpl' };

	if($data->{'SSL_SUPPORT'}) {
		$configs{"$data->{'DOMAIN_NAME'}_ssl.conf"} = {
			'redirect' => 'domain_redirect_ssl.tpl', 'normal' => 'domain_ssl.tpl'
		};

		$self->{'data'}->{'CERT'} = "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$data->{'DOMAIN_NAME'}.pem";
	}

	for(keys %configs) {
		# Schedule deletion of useless sections if needed
		if($data->{'FORWARD'} eq 'no') {
			$rs = $self->{'hooksManager'}->register(
				'beforeHttpdBuildConfFile', sub { $self->removeSection('suexec', @_) }
			);
			return $rs if $rs;

			$rs = $self->{'hooksManager'}->register(
				'beforeHttpdBuildConfFile', sub { $self->removeSection('cgi_support', @_) }
			) unless $data->{'CGI_SUPPORT'} eq 'yes';
			return $rs if $rs;

			$rs = $self->{'hooksManager'}->register(
				'beforeHttpdBuildConfFile', sub { $self->removeSection('php_enabled', @_) }
			) unless $data->{'PHP_SUPPORT'} eq 'yes';
			return $rs if $rs;

			$rs = $self->{'hooksManager'}->register(
				'beforeHttpdBuildConfFile', sub { $self->removeSection('php_disabled', @_) }
			) if ($data->{'PHP_SUPPORT'} eq 'yes');
			return $rs if $rs;

			$rs = $self->{'hooksManager'}->register(
				'beforeHttpdBuildConfFile', sub { $self->removeSection('fcgid', @_) }
			);
			return $rs if $rs;

			$rs = $self->{'hooksManager'}->register(
				'beforeHttpdBuildConfFile', sub { $self->removeSection('fastcgi', @_) }
			);
			return $rs if $rs;

			$rs = $self->{'hooksManager'}->register(
				'beforeHttpdBuildConfFile', sub { $self->removeSection('php_fpm', @_) }
			);
			return $rs if $rs;
		}

		$rs = $self->buildConfFile(
			$data->{'FORWARD'} eq 'no'
				? "$self->{'tplDir'}/$configs{$_}->{'normal'}" : "$self->{'tplDir'}/$configs{$_}->{'redirect'}",
			{ 'destination' => "$self->{'wrkDir'}/$_" }
		);
		return $rs if $rs;

		$rs = $self->installConfFile($_);
		return $rs if $rs;
	}

	# Build Apache sites - End

	# Build and install custom Apache configuration file
	$rs =	$self->buildConfFile(
		"$self->{'tplDir'}/custom.conf.tpl",
		{ 'destination' => "$self::apacheConfig{'APACHE_CUSTOM_SITES_CONFIG_DIR'}/$data->{'DOMAIN_NAME'}.conf" }
	) unless (-f "$self::apacheConfig{'APACHE_CUSTOM_SITES_CONFIG_DIR'}/$data->{'DOMAIN_NAME'}.conf");
	return $rs if $rs;

	# Enable all Apache sites
	$rs = $self->enableSite($_) for keys %configs;
	return $rs if $rs;

	$self->{'hooksManager'}->trigger('afterHttpdAddCfg');
}

=item _dmnFolders(\%data)

 Get Web folders list to create for the given domain or subdomain

 Param hash_ref Reference to a hash containing needed data
 Return array_ref Reference to an array containing list of Web folders to create

=cut

sub _dmnFolders($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my @folders = ();

	$self->{'hooksManager'}->trigger('beforeHttpdDmnFolders', \@folders);

	$self->{'hooksManager'}->trigger('afterHttpdDmnFolders', \@folders);

	@folders;
}

=item _addFiles(\%data)

 Add default directories and files for the given domain or subdomain

 Param hash_ref Reference to a hash containing needed data
 Return int 0 on sucess, other on failure

=cut

sub _addFiles($$)
{
	my $self = shift;
	my $data = shift;

	fatal('Hash reference expected') if ref $data ne 'HASH';

	my $rs = $self->{'hooksManager'}->trigger('beforeHttpdAddFiles', $data);
	return $rs if $rs;

	my $webDir = $data->{'WEB_DIR'};

	# Build domain/subdomain Web directory tree using skeleton from (eg /etc/imscp/etc/skel) - BEGIN

	my $skelDir = ($data->{'DOMAIN_TYPE'} eq 'dmn' || $data->{'DOMAIN_TYPE'} eq 'als')
		? "$self->{'cfgDir'}/skel/domain" : "$self->{'cfgDir'}/skel/subdomain";

	my ($tmpDir, $stdout, $stderr);

	if(-d $skelDir) {
		$tmpDir = File::Temp->newdir();

		$rs = execute("$main::imscpConfig{'CMD_CP'} -LRT $skelDir $tmpDir", \$stdout, \$stderr);
		debug($stdout) if $stdout;
		error($stderr) if $stderr && $rs;
		return $rs if $rs;
	} else {
		error("Skeleton directory $skelDir doesn't exist.");
		return 1;
	}

	# Build default domain/subdomain page if needed (if htdocs doesn't exist or is empty)
	# Remove it from Web directory tree otherwise
	if(! -d "$webDir/htdocs" || iMSCP::Dir->new('dirname' => "$webDir/htdocs")->isEmpty()) {
		if(-d "$tmpDir/htdocs") {
			# Test needed in case admin removed the index.html file from the skeleton
			if(-f "$tmpDir/htdocs/index.html") {
				my $fileSource = "$tmpDir/htdocs/index.html";
				$rs = $self->buildConfFile($fileSource, { 'destination' => $fileSource });
				return $rs if $rs;
			}
		} else {
			error("SkelDir must provide the 'htdocs' directory."); # TODO should we just create it instead?
			return 1;
		}
	} else {
		$rs = iMSCP::Dir->new('dirname' => "$tmpDir/htdocs")->remove() if -d "$tmpDir/htdocs";
		return $rs if $rs;
	}

	if(
		$data->{'DOMAIN_TYPE'} eq 'dmn' && -d "$webDir/errors" &&
		! iMSCP::Dir->new('dirname' => "$webDir/errors")->isEmpty()
	) {
		if(-d "$tmpDir/errors") {
			$rs = iMSCP::Dir->new('dirname' => "$tmpDir/errors")->remove() if -d "$tmpDir/errors";
			return $rs if $rs;
		} else {
			warning("SkelDir should provide the 'errors' directory.");
		}
	}

	# Build domain/subdomain Web directory tree using skeleton from (eg /etc/imscp/etc/skel) - END

	my $protectedParentDir = dirname($webDir);
	$protectedParentDir = dirname($protectedParentDir) while(! -d $protectedParentDir);
	my $isProtectedParentDir = 0;

	# Unprotect parent directory if needed
	if(isImmutable($protectedParentDir)) {
		$isProtectedParentDir = 1;
		clearImmutable($protectedParentDir);
	}

	# Unprotect Web root directory
	if(-d $webDir) {
		clearImmutable($webDir);
	} else {
		# Create Web directory
		$rs = iMSCP::Dir->new(
			'dirname' => $webDir
		)->make(
			{ 'user' => $data->{'USER'}, 'group' => $data->{'GROUP'}, 'mode' => 0750 }
		);
		return $rs if $rs;
	}

	# Copy Web directory tree to the Web directory
	$rs = execute("$main::imscpConfig{'CMD_CP'} -nRT $tmpDir $webDir", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $stderr && $rs;
	return $rs if $rs;

	# Remove uneeded directories/files (This is done at $webDir level instead of $tmpLevel to remove unneeded directory,
	# which, were copied by mistake using the hard coded skeleton as provided by previous i-MSCP versions
	if($data->{'DOMAIN_TYPE'} eq 'als') {
		for('backups', 'domain_disable_page', 'errors', '.htgroup', '.htpasswd') {
			if(-d "$webDir/$_") {
				$rs = iMSCP::Dir->new('dirname' => "$webDir/$_")->remove();
				return $rs if $rs;
			} elsif(-f _) {
				$rs = iMSCP::File->new('filename' => "$webDir/$_")->delFile();
				return $rs if $rs;
			}
		}
	}

	# Create other directories as returned by the dmnFolders() method
	for ($self->_dmnFolders($data)) {
		$rs = iMSCP::Dir->new(
			'dirname' => $_->[0]
		)->make(
			{ 'user' => $_->[1], 'group' => $_->[2], 'mode' => $_->[3] }
		);
		return $rs if $rs;
	}

	# Set permisions - Begin

	$rs = setRights($webDir, {'user' => $data->{'USER'}, 'group' => $data->{'GROUP'}, 'mode' => '0750'});
	return $rs if $rs;

	for(iMSCP::Dir->new('dirname' => $tmpDir)->getAll()) {
		$rs = setRights(
			"$webDir/$_", { 'user' => $data->{'USER'}, 'group' => $data->{'GROUP'}, 'recursive' => 1 }
		) if -d "$webDir/$_" && $_ ne 'domain_disable_page';
		return $rs if $rs;

		$rs = setRights(
			"$webDir/$_",
			{
				'dirmode' => '0750',
				'filemode' => '0640',
				'recursive' => ($_ eq '00_private' || $_ eq 'cgi-bin' || $_ eq 'htdocs') ? 0 : 1
			}
		) if -d _;
		return $rs if $rs;
	}

	# Set domain_disable_page pages owner and group
	$rs = setRights(
		"$webDir/domain_disable_page",
		{
			'user' => $main::imscpConfig{'ROOT_USER'},
			'group' => $self->getRunningGroup(),
			'recursive' => 1,
		}
	) if -d "$webDir/domain_disable_page";
	return $rs if $rs;

	if($data->{'WEB_FOLDER_PROTECTION'} eq 'yes') {
		# Protect Web root directory
		setImmutable($webDir);

		# Protect parent directory if needed
		setImmutable($protectedParentDir) if $isProtectedParentDir;
	}

	$self->{'hooksManager'}->trigger('afterHttpdAddFiles', $data);
}

=item END

 Code triggered at the very end of script execution.

 - Start or restart apache if needed
 - Remove old traffic logs directory if exists

 Return int Exit code

=cut

END
{
	my $self = Servers::httpd::apache_itk->getInstance();
	my $trafficDir = "$self::apacheConfig{'APACHE_LOG_DIR'}/traff";
	my $rs = 0;

	if($self->{'start'} && $self->{'start'} eq 'yes') {
		$rs = $self->start();
	} elsif($self->{'restart'} && $self->{'restart'} eq 'yes') {
		$rs = $self->restart();
	}

	$rs |= iMSCP::Dir->new('dirname' => "$trafficDir.old")->remove() if -d "$trafficDir.old";

	$? ||= $rs;
}

=back

=head1 AUTHORS

 Daniel Andreca <sci2tech@gmail.com>
 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
