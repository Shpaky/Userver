	package SERVER;

	use 5.10.0;

	use Cwd qw(chdir);

	use JSON;
	use FCGI;
	use POSIX;
	use Fcntl qw|:flock|;
	use Scalar::Util qw|blessed|;
	use Log::Log4perl qw(get_logger :levels);

	use IO::Socket;
	use IO::Socket::UNIX;
	use IO::Handle;

	our $logger;
	our $notice;


	$SERVER::EXPORT =
	{
		'kill_pid' => 'subroutine',
		'read_value_ff'	=> 'subroutine',
	};


	sub export_name
	{
		my $pack = caller;
		map { $SERVER::EXPORT->{$_} and local *myglob = eval('$'.__PACKAGE__.'::'.'{'.$_.'}'); *{$pack.'::'.$_} = *myglob } @_;
	}
	sub new 
	{ 
		my $class = shift;
		my $self = bless \{}, $class;
		return $self;
	}
	sub init_server
	{

		given ( $CONFIG::server )
		{
			when ('unix_socket')
			{
				our $pack ||= caller();
				unlink $CONFIG::path->{'socket'};
				${$pack.'::'.'server'} = IO::Socket::UNIX->new
				(
					Type => SOCK_STREAM(),
					Local => $CONFIG::path->{'socket'},
					Listen => $CONFIG::listen
				);
				chmod 0777, $CONFIG::path->{'socket'};
			}
			when ('inet_socket') {1}
			when ('fcgi')
			{
				our $pack ||= __PACKAGE__;
				unlink $CONFIG::path->{'socket'};
				my $socket = FCGI::OpenSocket($CONFIG::path->{'socket'}, $CONFIG::listen);
				${$pack.'::'.'server'} = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);				## FCGI::FAIL_ACCEPT_ON_INTR
				chmod 0777, $CONFIG::path->{'socket'};
			}
		}
	}
	sub accept_request
	{
		given ( $CONFIG::server )
		{
			when ('unix_socket')
			{
				${$pack.'::'.'conn'} = ${$pack.'::'.'server'}->accept();
			#	return ${$pack.'::'.'conn'}->isa('IO::Socket::UNIX') ? 1 : 0;
				return 1;
			}
			when ('inet_socket') {1}
			when ('fcgi')
			{
				${$pack.'::'.'server'}->Accept() >= 0;
			}
		}
	}
	sub fetch_request
	{
		given ( $CONFIG::server )
		{
			when ('unix_socket')
			{
				my $conn = ${$pack.'::'.'conn'};
		#		read ($conn, my $request, 10000);
		#		$request =~ s/%([0-9A-Fa-f][0-9A-Fa-f])/pack("c",hex($1))/ge;
		#		$request =~ tr/+/ /;
				my $request = <$conn>;
				return $request;
			}
			when ('inet_socket') {1}
			when ('fcgi')
			{
				return \%ENV;
			}
		}
	}
	sub init_sig_handler
	{
		my $pack = caller();
		map { $SIG{$_} = \&{'SERVER'.'::'.$_} } grep { &check_allowable_signals($_) } @{$_[0]};
	}
	sub reset_sig_handler
	{
		my $pack = caller();
		map { $SIG{$_} = 'DEFAULT' } grep { &check_allowable_signals($_) } @{$_[0]};
	}
	sub check_allowable_signals
	{
		return $CONFIG::signals->{$_[0]};
	}
	sub init_application
	{
		my $pack = caller();
		map {
			(
			  &SERVER::connect_module($CONFIG::applications->{$_}) and
			  lc(ref(\&{$CONFIG::applications->{$_}->{'module'}.'::'.$CONFIG::applications->{$_}->{'method'}})) eq 'code' and
			  $SERVER::applications->{$_} = \&{$CONFIG::applications->{$_}->{'module'}.'::'.$CONFIG::applications->{$_}->{'method'}} and
			  $CONFIG::apps_m eq 'single' ? chdir($CONFIG::applications->{$_}->{'catalog'}) : 1
			)
			? ( $logger->info('Приложение '.'|'.$_.'|'.' подключено, процесс'.'|'.$$.'|') )
			: ( $notice->warn('Не удалось подлючить приложение '.'|'.$_.'|'.', процесс'.'|'.$$.'|') )
		} grep { $logger->info('Подключение приложения '.'|'.$_.'|'.', процесс'.'|'.$$.'|') } keys %$CONFIG::applications;
	}
	sub connect_module
	{
		push @INC, $_[0]->{'catalog'};
		push @INC, $_[0]->{'libraly'};

		$_[0]->{'module'} !~ /^[a-z0-9:_\-]+$/i and $notice->warn('Не допустимое имя модуля'.'|'.$_[0]->{'module'}.'|') and return;

		my $module = $_[0]->{'module'};
		while ( $module =~ /(.*)(::[a-z0-9_\-]+)|[a-z0-9_\-]+$/i )
		{
			my $up_pack = $1;

			my $filename = $module;
			$filename =~ s|::+|/|g;
			$filename =~ /\.pm$/ or $filename .= '.pm';

			exists($INC{$filename}) or ( -f $_[0]->{'catalog'}.'/'.$filename && eval('require '.$module.';') ) or ( delete($INC{$filename}),$notice->warn('Ошибка подключения файла модуля'.'|'.$filename.'|'.', ошибка'.'|'.$!.':'.$@.'|'),return );
			$module = $up_pack;
		}
		return !$module;
	}
	sub call_application
	{
		if ( $CONFIG::server eq 'unix_socket' )
		{
			given ( $CONFIG::navigation->{eval{eval("$_[0];")->{'route'}} or eval{decode_json($_[0])->{'route'}}} )
			{
				when ('HPVF')
				{
					$CONFIG::apps_m eq 'multiple' and chdir($CONFIG::applications->{'HPVF'}->{'catalog'});
					$logger->info('Выполнена маршрутизация на приложение '.'|'.$CONFIG::navigation->{decode_json($_[0])->{'route'}}.'|'.', по запросу '.'|'.decode_json($_[0])->{'route'}.'|'.', процесс'.'|'.$$.'|');
					$SERVER::applications->{'HPVF'}->(decode_json($_[0]));
				}
				when ('Statistic')
				{
					$CONFIG::apps_m eq 'multiple' and chdir($CONFIG::applications->{'Statistic'}->{'catalog'});
					$logger->info('Выполнена маршрутизация на приложение '.'|'.$CONFIG::navigation->{$request->{'route'}}.'|'.', по запросу '.'|'.$request->{'route'}.'|'.', процесс'.'|'.$$.'|');
					$SERVER::applications->{'Statistic'}->($request);
				}
			}
		}
		else
		{
			## fsgi
			chdir($CONFIG::applications->{'Palace'}->{'catalog'});
			$logger->info('Выполнена маршрутизация на приложение '.'|'.$CONFIG::navigation->{$_[0]->{'REQUEST_URI'}}.'|'.', по запросу '.'|'.$_[0]->{'REQUEST_URI'}.'|'.', процесс'.'|'.$$.'|');
			$SERVER::applications->{'Palace'}->($_[0]);
		}
	}
	sub init_log
	{
		my $log = -f $_[0] ? shift : $CONFIG::path->{'conf_log'};
		Log::Log4perl->init($log);
	}
	sub get_logs
	{
		my $pack = $_[0] || caller();
		if ( not defined(wantarray()) )
		{
			&logger($pack);
			&notice($pack);
		}
		elsif ( wantarray() )
		{
			return ( &logger($pack), &notice($pack) );
		}
	}
	sub logger
	{
		my $pack = $_[0] || caller();
		my $append = $CONFIG::logs->{$pack}->{'logger'};

		if ( not defined(wantarray()) )
		{
			${$pack.'::'.'logger'} = get_logger($append);
		}
		else
		{
			return get_logger($append);
		}
	}
	sub notice
	{
		my $pack = $_[0] || caller();
		my $append = $CONFIG::logs->{$pack}->{'notice'};

		if ( not defined(wantarray()) )
		{
			${$pack.'::'.'notice'} = get_logger($append);
		}
		else
		{
			return get_logger($append);
		}
	}
	sub REAPER
	{
		while (( $USERVER::pid = waitpid(-1,WNOHANG)) > 0)
		{
			$notice->error('Уничтожен потомок, процесс сервер упал!'.'|'.$USERVER::pid.'|');
	#		last;
		}
		$USERVER::SIG{CHLD} = \&REAPER;
	}
	sub INT
	{
		$notice->warn('Получен сигнал '.'|'.$_[0].'|'.' завершения работы сервера, процесс'.'|'.$$.'|');

		local($SIG{CHLD}) = 'IGNORE';
		map {
			delete $USERVER::childrens->{$_} and $USERVER::children-- and $notice->warn('Уничтожен потомок, процесс сервер завершён'.'|'.$_.'|')
		} grep { kill_pid(2, $_) } keys %$USERVER::childrens;

		$notice->warn('Процесс сервер остановлен, процесс'.'|'.$$.'|');
		exit;
	}
	sub CHLD
	{
		state $sigset ||= POSIX::SigSet->new($_[0]);
		sigprocmask(SIG_BLOCK, $sigset) or die "Не удалось заблокировать '$_[0]' для обработчика: $!\n";

		$USERVER::SIG{CHLD} = 'IGNORE';
		&REAPER;

		sigprocmask(SIG_UNBLOCK, $sigset) or die "Не удалось разблокировать '$_[0]' для обработчика: $!\n";
	}
	sub USR1
	{
		$_[1] > 0 || ( state $sigset ||= POSIX::SigSet->new($_[0]) and sigprocmask(SIG_BLOCK, $sigset) or die "Не удалось заблокировать '$_[0]' для обработчика: $!\n" );

		local $SIG{PIPE} = &PIPE;
		$_[1] > 0 || $logger->info('Получен сигнал от мониторинга, процесс'.'|'.$$.'|');
		if ( -p $CONFIG::path->{'pipe'} )
		{
			if ( &write_pipe($CONFIG::path->{'pipe'},time) )
			{
				$logger->info('Отправлен ответ на запрос от мониторинга, процесс'.'|'.$$.'|');
				sigprocmask(SIG_UNBLOCK, $sigset) or die "Не удалось разблокировать '$_[0]' для обработчика: $!\n";
			}
			else
			{
				$_[1] > 0 || &USR1($_[0],1);
			}
		}
		else
		{
			if ( &create_pipe($CONFIG::path->{'pipe'},0700) )
			{
				$logger->info('Создан именованный канал '.'|'.$CONFIG::path->{'pipe'}.'|'.', процесс'.'|'.$$.'|');
				$_[1] > 1 || &USR1($_[0],2);
			}
			else
			{
				$notice->error('Не удалось создать именованный канал '.'|'.$CONFIG::path->{'pipe'}.'|'.', процесс'.'|'.$$.'|');

				sigprocmask(SIG_UNBLOCK, $sigset) or die "Не удалось разблокировать '$_[0]' для обработчика: $!\n";
			}
		}

		$_[1] > 0 || sigprocmask(SIG_UNBLOCK, $sigset) or die "Не удалось разблокировать '$_[0]' для обработчика: $!\n";
	}
	sub PIPE
	{
		local $SIG{PIPE} = 'IGNORE';
		local $SIG{PIPE} = 'DEFAULT';
	}
	sub USR2
	{

		state $sigset ||= POSIX::SigSet->new($_[0]);
		sigprocmask(SIG_BLOCK, $sigset) or die "Не удалось заблокировать '$_[0]' для обработчика: $!\n";

		$notice->warn('Получен сигнал об изменении конфигурации сервера, процесс'.'|'.$$.'|');
		$SIG{CHLD} = 'IGNORE';
		no CONFIG;
		map {
			delete $USERVER::childrens->{$_} and $USERVER::children-- and $notice->warn('Уничтожен потомок, процесс сервер завершён'.'|'.$_.'|')
		} grep {  kill_pid(2, $_) } keys %$USERVER::childrens;
		use CONFIG;

		sigprocmask(SIG_UNBLOCK, $sigset) or die "Не удалось разблокировать '$_[0]' для обработчика: $!\n";
	}
	sub loop 
	{
		
		if ( $USERVER::pid && kill_pid(0,$USERVER::pid) )
		{   	
			$logger->info('Проверка потомка, процесс чекер-соединений существует'.'|'.$USERVER::pid.'|');
			return;
		} 
		else 
		{
			$notice->warn('Проверка потомка, процесс чекер-соединений не существует!'.'|'.$USERVER::pid.'|');
			if ( $USERVER::pid = fork() )
			{ 

				$logger->info('Порожден потомок, процесс чекер-соединений!'.'|'.$USERVER::pid.'|');
				return; 
			} 
			else   
			{
				while ( 1 )
				{
					sleep 1;
					&SERVER::check_connects($_) for (0..9);
				}
#				eval{exit;};
			}
		}
	}
	sub kill_pid
	{ 
		my ( $sig, $pid ) = @_;
			
		kill $sig => $pid;	
	}
	sub check_childs
	{
		map { delete $USERVER::childrens->{$_} and $USERVER::children-- and $notice->error('Проверка процесса-потомка, процесс сервер не отвечает!'.'|'.$_.'|') } grep { ! kill_pid(0, $_) } keys %$USERVER::childrens;
	}
	sub get_dates
	{
		my $c = shift if $_[0] eq __PACKAGE__ || ref($_[0]) eq __PACKAGE__;
		my $t = shift;

		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($t);

		return
		([
			$wday,
			sprintf('%02d%02d%02d',$year%100,$mon+1,$mday),
			sprintf('%02d.%02d.%02d %02d:%02d:%02d',$mday,$mon+1,$year%100,$hour,$min,$sec),
			sprintf('%04d-%02d-%02d %02d:%02d:%02d',$year+1900,$mon+1,$mday,$hour,$min,$sec),
			sprintf('%04d%02d%02d',$year+1900,$mon,$mday),
			[ $hour, $mday, $mon, $year, $wday, $yday ],
		]);
	}
	sub locked_open
	{
		my ( $path ) = @_;

		( $logger, $notice ) = &get_logs();

		if ( sysopen OL, $path, O_WRONLY|O_CREAT|O_TRUNC|O_EXCL )
		{
			flock ( OL, LOCK_EX );
			print OL $$;
			$logger->info('Запуск приложения, сервер запущен, процесс '.'|'.$$.'|');
		}
		else
		{
			open RL, $path; my $pid = <RL>; close RL;
			$notice->error('Запуск приложения, процесс '.'|'.$$.'|'.' ошибка запуска - сервер уже запущен, процесс '.'|'.$pid.'|');
			die;
		}
	}
	sub write_pipe
	{
		my ( $pipe, $data ) = @_;

		open  WP,'>',$pipe;
		print WP $data;
		close WP;

#		return $! ? undef : 1;
	}
	sub create_pipe
	{
		my ( $path, $mode ) = @_;

		POSIX::mkfifo($path, $mode);
	}
	sub write_data
	{
		my ( $path, $data ) = @_;

		open  WD, '>>', $path;
		print WD Data::Dumper->Dump([$data],['data']);
		close WD;
	}
	sub read_value_ff
	{
		my $path = shift;
		my $v;
		open RP, $path; $v .= $_ for <RP>; close RP;

		return $v;
	}
	sub check_apps_mode
	{
		state $apps_m ||= $CONFIG::apps_m eq 'multiple' ? 1 : 0;

		return $apps_m;
	}
	sub check_hand_type
	{
		state $hand_t ||= $CONFIG::handler eq 'common' ? 1 : 0;

		return $hand_t;
	}
	1;
