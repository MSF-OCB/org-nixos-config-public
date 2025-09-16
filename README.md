# Introduction

This is the public version of the code that MSF-OCB uses to manage servers across many locations worldwide. The code was [first presented at FOSDEM 2025 in the NixOS devroom](https://fosdem.org/2025/schedule/event/fosdem-2025-5165-nixos-doctors-without-borders-msf-why-we-use-it-and-how/). The code is mostly written in [the Nix language](https://nix.dev/manual/nix/2.28/language/) with some Python and Shell script mixed in.

## Features: what does this code do?

This code is designed to facilitate low-touch management and system administration tasks across a highly distributed fleet of mission-critical Linux servers, hosting containerised applications.

The code allows servers to be configured from different branches, for example to configure test machines from a staging branch, and for major upgrades to be rolled out in staggered waves.

## Why would I want to use this code?

Several implementation choices are particular to the specific operating context of MSF, and these are discussed in the presentation above.

If you can boot a K8S cluster in the cloud for all your stuff, that's great! This is not that.

This code is designed for managing a large fleet of servers:

- Distributed across non-standard environments
- With low, unstable or fragile Internet connectivity
- With few local staff on hand to support
- Who may be a long way away (hardware that is difficult to get to)
- Distributed along a 'remote-managed appliance' model
- Operating in complicated, delicate or sensitive political enviroments.

# Documentation & getting started

To get started, you will need to fork this repo and then adapt the code under `org-config/.` Some examples have been provided. If you want to administer your servers remotely, you will need to configure and install an SSH relay.

[More documentation is available on the wiki](https://github.com/MSF-OCB/org-nixos-config-public/wiki).

# Roadmap

At present, to make use of the code you need to fork the entire codebase, including the modules. The modules could in theory be made external to the organisation-specific code, and then pulled in from separate repo(s).

This would require a large refactoring, but it would make it much easier for end users. It would also make collaborating on module evolution more organic. However, it would also

# Security

We take the security of this project seriously. If you believe you have found a security vulnerability, **please do not create a public GitHub issue**. Instead, report it responsibly through one of the following channels:

- Email: cybersecurity@brussels.msf.org
- HackerOne:

We will do our best to acknowledge your report promptly, investigate, and take the necessary actions.

# Contributing

Please report bugs via the GitHub issue tracker.

For more information on how to contribute and some notes on our constraints, please see [CONTRIBUTING.md](CONTRIBUTING.md).

# Why publish?

Following our presentation in January 2025, many members of the NixOS community reached out to us, volunteering their time and expertise. This public version of our code contains no secrets, configuration or data concerning MSFs operations and is designed to make it easier to accept volunteer contributions.

At the same time, our hope is that this code will serve as a starting point for other organisations engaged in humanitarian work who have similar needs.

We would like to extend our sincere thanks to the volunteers who have given freely of their time and energy to make the code what it is today.

# License

This code is released under the [BSD 3 clause license](LICENSE).

# Credits

The original code was written by [@r-vdp](https://github.com/r-vdp) while working at MSF Belgium. Since then the code has been maintained and evolved by various members of MSF BE IT unit, with continued input and advice from Ramses and other members of the NixOS community, including [@zimbatm](http://github.com/zimbatm) and [@jfroche](https://github.com/jfroche).

# About Médecins Sans Frontières

Médecins Sans Frontières (aka MSF, or Doctors Without Borders) is a humanitarian organisation that provides medical assistance to people affected by conflict, epidemics, disasters, or exclusion from healthcare.

Our teams are made up of tens of thousands of health professionals, logistic and administrative staff - most of them hired locally. Our actions are guided by medical ethics and the principles of **impartiality, independence and neutrality.** We are a non-profit, self-governed, member-based organisation.

We provide medical humanitarian assistance to save lives and ease the suffering of people in crisis situations in more than 70 countries.

We rely entirely on donations from individuals. **98 per cent of our 2023 income came from some 7.3 million private donors**. It is thanks to the generosity of these private supporters – mainly individuals like you – that we are able to operate independently and provide humanitarian assistance in some of the world’s most insecure environments and forgotten crises.

# What is OCB?

Here at Operational Centre Brussels, our team helps support MSF operations in 35+ countries including Afghanistan, Haiti, the Occupied Palestinian territories, and Ukraine.

For more information, please see [msf-azg.be](https://msf-azg.be) for MSF Belgium and [msf.org](https://msf.org) for MSF worldwide.
