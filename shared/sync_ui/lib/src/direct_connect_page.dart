import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sync_net/sync_net.dart';

import '../l10n/gen/app_localizations.dart';

import 'direct_link.dart';
import 'layout.dart';
import 'qr_pairing.dart';
import 'storage.dart';
import 'sync_page.dart';

/// The direct tab: its own place in the app, because a way of reaching a device
/// is not a mode of the device list, and a switch inside that list hid it from
/// anyone who had not gone looking.
class DirectConnectPage extends StatelessWidget {
  const DirectConnectPage({
    super.key,
    required this.self,
    required this.trust,
    this.folders,
    this.links,
    this.scanner,
    this.server,
    this.autoLoad = true,
  });

  final DeviceInfo self;
  final TrustStore trust;

  /// What this device shares, handed on to the sync screen so a folder already
  /// chosen here is not asked for again.
  final SharedFolders? folders;
  final DirectLinkControls? links;
  final QrScanner? scanner;
  final PeerServer? server;
  final bool autoLoad;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).directConnect)),
      body: DirectConnectPanel(
        self: self,
        trust: trust,
        folders: folders,
        links: links,
        scanner: scanner,
        server: server,
        autoLoad: autoLoad,
      ),
    );
  }
}

/// Connecting two devices with no network between them.
///
/// Discovery needs a network that carries multicast or broadcast between the
/// two devices, and there are ordinary situations with no such network: a phone
/// on mobile data, a guest Wi-Fi that isolates its clients, a laptop with no
/// Wi-Fi at all. This panel is for those, and there are two ways to use the
/// app: on a shared network, where the device list does everything, or here,
/// where one device shows a code and the other reads it.
///
/// That is the whole of the screen, deliberately. It used to also offer the
/// parts a code is made of - raise a hotspot, open the Wi-Fi settings, read
/// this device's addresses off a list, type the other device's address, sweep
/// the link for whatever answers - and every one of those is a thing the person
/// in front of it should not have to know exists. Showing a code raises the
/// hotspot if one is needed; scanning it joins that network, finds which
/// address answers and pairs on a one-time token. Nothing is read out, typed or
/// compared.
///
/// Bluetooth was the obvious alternative and is the wrong tool: it needs native
/// code on both platforms (a plugin on Android, BlueZ over D-Bus on Linux),
/// which this project deliberately does not have, and even at its best it moves
/// a folder of notes an order of magnitude slower than a cable or a hotspot.
class DirectConnectPanel extends StatefulWidget {
  const DirectConnectPanel({
    super.key,
    required this.self,
    required this.trust,
    this.folders,
    this.links,
    this.scanner,
    this.server,
    this.autoLoad = true,
  });

  final DeviceInfo self;
  final TrustStore trust;

  /// What this device shares, so the sync screen this panel opens knows where a
  /// folder lands here without asking a question already answered.
  final SharedFolders? folders;

  /// Reads QR codes with the camera. Null where there is none.
  final QrScanner? scanner;

  /// The listening server, so a code shown here can carry a token it will
  /// accept. Without one this device can be dialled but cannot show a code.
  final PeerServer? server;

  /// What this platform can do about making a link: raise a hotspot, join one.
  /// Null where it can do neither, which is the desktop - there a code is still
  /// worth showing, since the addresses in it are reachable from anything on
  /// the same network.
  final DirectLinkControls? links;

  /// Whether to read this device's addresses on open. Off in widget tests,
  /// where enumerating real interfaces is neither wanted nor stable.
  final bool autoLoad;

  @override
  State<DirectConnectPanel> createState() => _DirectConnectPanelState();
}

class _DirectConnectPanelState extends State<DirectConnectPanel> {
  /// This device's addresses, read to go into the code. They are not shown:
  /// an address is what the scanner dials, not something a person acts on.
  List<LocalAddress> _addresses = const [];

  bool _canHostHotspot = false;

  /// The hotspot this screen raised to carry the code's address, if it had to.
  HotspotCredentials? _hotspot;

  bool _connecting = false;
  String? _failure;

  /// The code currently on screen, and the token it carries. Both die together:
  /// a token outliving its code is a pairing nobody is watching for.
  QrPayload? _shown;
  QrPairingToken? _shownToken;
  bool _preparingQr = false;
  String? _pairedWith;
  StreamSubscription<IncomingPairing>? _pairings;

  /// The links that are two devices and nothing else: a cable, or a hotspot.
  List<LocalAddress> get _directLinks =>
      [for (final a in _addresses) if (a.kind.isDirect) a];

  @override
  void initState() {
    super.initState();
    if (widget.autoLoad) {
      _loadAddresses();
      _askWhatIsPossible();
    }
    // The other device pairing off this screen's code is news worth showing
    // here, where the code is: it is the end of what this screen was for.
    _pairings = widget.server?.pairingRequests.listen((request) {
      if (!mounted || !request.settled) return;
      setState(() {
        _pairedWith = request.peer.name;
        _shown = null;
        _shownToken = null;
      });
    });
  }

  @override
  void dispose() {
    _pairings?.cancel();
    // The code is off screen the moment this is: nothing may pair on a token
    // nobody is looking at.
    if (widget.server?.qrToken == _shownToken) widget.server?.qrToken = null;
    // A hotspot raised for a code nobody is showing any more is a network left
    // running on somebody's phone battery.
    if (_hotspot != null) widget.links?.stopHotspot();
    super.dispose();
  }

  Future<void> _askWhatIsPossible() async {
    final can = await widget.links?.canHostHotspot() ?? false;
    if (mounted) setState(() => _canHostHotspot = can);
  }

  Future<void> _loadAddresses() async {
    final found = await localAddresses();
    if (mounted) setState(() => _addresses = found);
  }

  // ------------------------------------------------------------------- link

  /// Raises the hotspot the code's address will be on. Not a button: it is part
  /// of showing a code, and a code carrying an address on a network the other
  /// device cannot reach is a code that scans and then fails.
  Future<void> _startHotspot() async {
    final credentials = await widget.links?.startHotspot();
    if (!mounted) return;
    setState(() => _hotspot = credentials);
    // The hotspot brings up an interface of its own, and its address is what
    // the other device will be told to dial.
    if (credentials != null) await _loadAddresses();
  }

  Future<void> _stopHotspot() async {
    if (_hotspot == null) return;
    await widget.links?.stopHotspot();
    if (!mounted) return;
    setState(() => _hotspot = null);
    await _loadAddresses();
  }

  // --------------------------------------------------------------------- qr

  /// Puts a code on screen with everything the other device needs: the network
  /// to join, where to dial, and a one-time token that lets it pair without
  /// anybody comparing digits.
  ///
  /// The hotspot comes up as part of showing the code, because a code carrying
  /// an address on a network the other device cannot reach would be a code that
  /// scans and then fails.
  Future<void> _showQr() async {
    final server = widget.server;
    if (server == null) return;

    setState(() {
      _preparingQr = true;
      _pairedWith = null;
      _failure = null;
    });

    if (_directLinks.isEmpty && _canHostHotspot) {
      await _startHotspot();
      if (!mounted) return;
      // Worth saying, and only here: without it the code still goes up, on
      // whatever network this device is already on, and that may well be the
      // network the other device is on too.
      if (_hotspot == null) {
        setState(() => _failure = AppLocalizations.of(context).hotspotFailed);
      }
    }
    await _loadAddresses();
    if (!mounted) return;

    // Direct links first: an address on the hotspot just raised is the one the
    // scanner will be able to reach, whatever else this device is attached to.
    final ordered = [
      for (final address in _addresses)
        if (address.kind.isDirect) address.address,
      for (final address in _addresses)
        if (!address.kind.isDirect && address.kind != LinkKind.mobile)
          address.address,
    ];

    final token = QrPairingToken.generate();
    server.qrToken = token;

    setState(() {
      _preparingQr = false;
      _shownToken = token;
      _shown = QrPayload(
        name: widget.self.name,
        platform: widget.self.platform,
        addresses: ordered,
        port: widget.self.port,
        token: token.value,
        wifiSsid: _hotspot?.ssid,
        wifiPassphrase: _hotspot?.passphrase,
      );
    });
  }

  /// Takes the code down, and with it the hotspot it was raised for: nobody is
  /// coming to scan a code that is not on screen, and the network was only ever
  /// there to carry it.
  ///
  /// A code that was scanned does not come through here - the pairing takes it
  /// off screen itself, and that hotspot is the network the two of them are
  /// about to sync over.
  Future<void> _hideQr() async {
    if (widget.server?.qrToken == _shownToken) widget.server?.qrToken = null;
    setState(() {
      _shown = null;
      _shownToken = null;
    });
    await _stopHotspot();
  }

  /// Reads the other device's code and does everything it says: joins the
  /// network it names, finds which of its addresses answers, and pairs with the
  /// token it carries - no digits to compare, because scanning the code is the
  /// stronger version of that check.
  Future<void> _scanQr() async {
    final scanner = widget.scanner;
    if (scanner == null) return;
    final l10n = AppLocalizations.of(context);

    final scanned = await scanner.scan(context);
    if (scanned == null || !mounted) return;

    final payload = QrPayload.decode(scanned);
    if (payload == null) {
      setState(() => _failure = l10n.qrNotOurs);
      return;
    }

    final cancel = Completer<void>();
    _cancelDial = cancel;
    setState(() {
      _connecting = true;
      _failure = null;
    });

    if (payload.hasWifi && widget.links != null) {
      final joined = await widget.links!
          .joinWifi(payload.wifiSsid!, payload.wifiPassphrase ?? '');
      if (!mounted) return;
      if (!joined) {
        setState(() {
          _connecting = false;
          _failure = l10n.qrJoinFailed(payload.wifiSsid!);
        });
        return;
      }
      // The network has just come up; the far end needs a moment to be
      // listening on it.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
    }

    for (final address in payload.addresses) {
      if (cancel.isCompleted) break;
      if (!await _reachable(address, payload.port, cancel.future)) continue;
      if (!mounted) return;

      final result = await PairingClient(widget.self, widget.trust).pair(
        address,
        payload.port,
        token: payload.token,
        cancel: cancel.future,
      );
      if (!mounted) return;

      if (result.isPaired && result.peer != null) {
        final trusted = await widget.trust.get(result.peer!.id);
        if (trusted == null || !mounted) return;
        setState(() => _connecting = false);
        await _openSync(
          trusted,
          DeviceInfo(
            id: trusted.id,
            name: trusted.name,
            platform: trusted.platform,
            port: payload.port,
            address: address,
          ),
        );
        return;
      }

      setState(() {
        _connecting = false;
        _failure = l10n.directFailed(
            '$address:${payload.port}', result.error ?? l10n.noResult);
      });
      return;
    }

    setState(() {
      _connecting = false;
      // Giving up is not a failure to report back.
      _failure = cancel.isCompleted ? null : l10n.qrUnreachable(payload.name);
    });
  }

  // ---------------------------------------------------------------- dialling

  /// Fires when the user gives up while a connection is still being made.
  Completer<void>? _cancelDial;

  void _cancelConnecting() {
    if (_cancelDial?.isCompleted == false) _cancelDial!.complete();
  }

  /// Whether anything at all is listening there, answered in a few seconds
  /// rather than the transport's patient ten - or the moment the user gives up.
  Future<bool> _reachable(String host, int port, Future<void> cancel) async {
    try {
      final conn = await PeerConnection.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
        cancel: cancel,
      );
      await conn.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openSync(TrustedPeer trusted, DeviceInfo device) async {
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SyncPage(
        self: widget.self,
        trusted: trusted,
        device: device,
        folders: widget.folders,
        // Scanning a code is asking for the sync too: nobody points a camera
        // at another device to admire the pairing.
        autoSync: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return ContentPane(
      child: ListView(
      padding: const EdgeInsets.fromLTRB(Layout.gutter, Layout.gutter,
          Layout.gutter, Layout.section + Layout.snug),
      children: [
        // The way this is meant to go: one device shows a code, the other
        // reads it, and nothing is typed or compared by anybody.
        _QrActions(
          canShow: widget.server != null,
          canScan: widget.scanner != null,
          preparing: _preparingQr,
          busy: _connecting,
          showing: _shown != null,
          onShow: _showQr,
          onHide: _hideQr,
          onScan: _scanQr,
        ),
        if (_pairedWith != null) ...[
          const SizedBox(height: Layout.gap),
          _PairedNotice(name: _pairedWith!),
        ],
        if (_shown != null) ...[
          const SizedBox(height: Layout.gutter),
          Center(child: PairingQrCode(data: _shown!.encode())),
          const SizedBox(height: Layout.gutter),
          // What the code carries - a network, an address, a key - is between
          // the two devices. All the person holding this one has to know is
          // how long to keep it up.
          Text(
            l10n.qrKeepOnScreen,
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.4),
          ),
        ],
        // The scan is several seconds of joining a network and knocking on
        // addresses, and it has to be possible to call off.
        if (_connecting) ...[
          const SizedBox(height: Layout.gutter),
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Layout.gap),
              Expanded(child: Text(l10n.directConnecting)),
              TextButton(
                onPressed: _cancelConnecting,
                child: Text(l10n.connectCancel),
              ),
            ],
          ),
        ],
        if (_failure != null) ...[
          const SizedBox(height: Layout.gap),
          Text(
            _failure!,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: Layout.section),
        _NoNetworkNote(),
      ],
      ),
    );
  }
}

/// The one thing no button on this screen can fix, said once at the bottom:
/// mobile data alone cannot carry a direct connection, however many bars it
/// shows. Worth stating, because it is the assumption people arrive with.
class _NoNetworkNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.tips_and_updates_outlined,
              size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppLocalizations.of(context).directHowTo,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pair of buttons this screen is really about.
class _QrActions extends StatelessWidget {
  const _QrActions({
    required this.canShow,
    required this.canScan,
    required this.preparing,
    required this.busy,
    required this.showing,
    required this.onShow,
    required this.onHide,
    required this.onScan,
  });

  final bool canShow;
  final bool canScan;
  final bool preparing;
  final bool busy;
  final bool showing;
  final Future<void> Function() onShow;
  final VoidCallback onHide;
  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (canScan)
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy || preparing ? null : onScan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(l10n.qrScan),
                ),
              ),
            if (canScan && canShow) const SizedBox(width: Layout.gap),
            if (canShow)
              Expanded(
                child: showing
                    ? OutlinedButton.icon(
                        onPressed: onHide,
                        icon: const Icon(Icons.visibility_off),
                        label: Text(l10n.qrHide),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: busy || preparing ? null : onShow,
                        icon: preparing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.qr_code_2),
                        label: Text(
                            preparing ? l10n.hotspotStarting : l10n.qrShow),
                      ),
              ),
          ],
        ),
        const SizedBox(height: Layout.snug),
        Text(
          canScan ? l10n.qrExplain : l10n.qrExplainNoCamera,
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant, height: 1.45),
        ),
      ],
    );
  }
}

/// The other device took the code and paired. Said here because this is the
/// screen that was waiting for it.
class _PairedNotice extends StatelessWidget {
  const _PairedNotice({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(Layout.gap),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: Layout.cardCorners,
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: colors.onPrimaryContainer, size: 20),
          const SizedBox(width: Layout.gap),
          Expanded(
            child: Text(
              AppLocalizations.of(context).pairedWith(name),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: colors.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
