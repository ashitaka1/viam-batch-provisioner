# Product

## Outcomes

### Machines provision themselves

A machine goes from bare hardware to a named host online in Viam with nobody at a console.

**Signal:** A batch of x86 machines and Pis comes back as named hosts online at app.viam.com, with no monitor, keyboard, or person at any machine during the run.

### Anyone trusted in the shop can provision

A provisioner works from their own Mac or iPhone, with no terminal and no access to the server.

**Signal:** A provisioner who has never touched the server Mac sets up an environment and provisions a batch from their own device, without opening a terminal.

### The server is just an app

The provisioning server installs like any Mac app and runs unattended, with nothing installed beside it.

**Signal:** On a fresh Mac with no Python, Docker, Homebrew, or dnsmasq, installing the app and turning on server mode gives a server that answers PXE machines, and keeps answering after a reboot with nobody logged in.

### Operators do other tasks without tending to installations

A provisioner starts a batch and turns to other work.

**Signal:** A provisioner starts a batch and leaves the app. Without opening it again, they learn when the batch is ready, and within minutes when a machine fails, with where it stopped and why.
