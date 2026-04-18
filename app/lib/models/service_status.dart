enum ServiceState { stopped, starting, running, stopping, error }

class ServiceStatus {
  const ServiceStatus({
    required this.state,
    this.message,
  });

  final ServiceState state;
  final String? message;

  static const stopped = ServiceStatus(state: ServiceState.stopped);

  bool get isRunning => state == ServiceState.running;
  bool get isBusy =>
      state == ServiceState.starting || state == ServiceState.stopping;
}

class ServicesStatus {
  const ServicesStatus({
    this.http = ServiceStatus.stopped,
    this.dnsmasq = ServiceStatus.stopped,
    this.watcher = ServiceStatus.stopped,
  });

  final ServiceStatus http;
  final ServiceStatus dnsmasq;
  final ServiceStatus watcher;

  bool get allRunning => http.isRunning && dnsmasq.isRunning && watcher.isRunning;
  bool get anyRunning => http.isRunning || dnsmasq.isRunning || watcher.isRunning;
  bool get anyBusy => http.isBusy || dnsmasq.isBusy || watcher.isBusy;

  ServicesStatus copyWith({
    ServiceStatus? http,
    ServiceStatus? dnsmasq,
    ServiceStatus? watcher,
  }) {
    return ServicesStatus(
      http: http ?? this.http,
      dnsmasq: dnsmasq ?? this.dnsmasq,
      watcher: watcher ?? this.watcher,
    );
  }
}
