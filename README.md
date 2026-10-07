# mks-infra

Helm chart that installs the base resources every Nectar Managed Kubernetes
Service (MKS) cluster gets. It is deployed by Argo CD from the `mks-argocd-*`
repositories with values layered per cluster; see those repositories for how
clusters are registered.

| Resource | Purpose |
|---|---|
| `GatewayClass default` and `EnvoyProxy envoy-gateway-system/default-proxy-config` | One Envoy Gateway data plane, pinned to the cluster's floating IP |
| `Gateway mks-infra/default` | The platform Gateway: port 80 only, open to customer `ListenerSet`s |
| `HTTPRoute mks-infra/https-redirect` | Redirects every plain HTTP request to HTTPS |
| `ClusterIssuer letsencrypt` and `letsencrypt-staging` | ACME HTTP-01 issuers that solve challenges through the Gateway |
| `ClusterRole project-admin`, `ClusterRoleBinding project-admins`, `ValidatingAdmissionPolicy restrict-project-admins` | Customer access: everything except writes to platform namespaces and objects |
| Monitors and alert rules under `files/prometheus/` | Optional, with `monitoring.enabled` |

## Who owns what on the Gateway

The platform owns the IP address, the Envoy deployment, the Gateway object,
port 80 and the certificate issuers. Everything that names a hostname belongs
to the cluster's users: they add listeners to the Gateway with `ListenerSet`
resources in their own namespaces, attach routes to those listeners and get
certificates from cert-manager by annotation. Nothing on the platform side
changes when a hostname is added or removed.

The Gateway accepts `ListenerSet`s from every namespace
(`gateway.allowedListeners.from: All`). Listeners defined on the Gateway
itself always win a conflict; between `ListenerSet`s the older one wins, so a
new conflicting listener never takes traffic from an existing one.

## Using the Gateway

### Before you start

- Find the cluster's address: `kubectl -n mks-infra get gateway default`
  prints it in the `ADDRESS` column.
- Point your hostname at that address in DNS before asking for a certificate.
  Let's Encrypt validates over HTTP on port 80, so the name must resolve
  publicly and the request must reach the Gateway.
- Create a namespace for your application if you have not already.

### Add a hostname

A `ListenerSet` attaches one or more listeners to the platform Gateway. This
one terminates TLS for a single hostname on port 443 and asks cert-manager
for the certificate:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: ListenerSet
metadata:
  name: web
  namespace: myapp
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  parentRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: default
    namespace: mks-infra
  listeners:
    - name: myapp
      hostname: myapp.example.org
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: myapp-tls
```

cert-manager creates a `Certificate` named `myapp-tls` in the `myapp`
namespace and stores the issued certificate in a Secret of the same name.
Add a listener per hostname; one `ListenerSet` can hold up to 64.

### Route traffic

Routes attach to the `ListenerSet`, not to the Gateway. `sectionName` picks
the listener:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      name: web
      sectionName: myapp
  hostnames:
    - myapp.example.org
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

By default a `ListenerSet` only accepts routes from its own namespace. To
attach routes from other namespaces, set `allowedRoutes.namespaces.from` on
the listener, exactly as on a Gateway listener.

### Check status

```sh
kubectl -n myapp get listenerset web -o yaml     # status.conditions: Accepted, Programmed; per-listener Conflicted
kubectl -n myapp get certificate,order,challenge   # certificate READY=True once issued
kubectl -n myapp get httproute myapp -o yaml       # status.parents[].conditions: Accepted, ResolvedRefs
curl -I https://myapp.example.org
```

While a certificate is being issued, cert-manager creates a temporary
`HTTPRoute` in your namespace for the challenge; it lists both the Gateway
and your `ListenerSet` as parents and disappears when the order completes.

### Certificates

- `cert-manager.io/cluster-issuer: letsencrypt` issues production
  certificates. Use `letsencrypt-staging` while setting up DNS or testing;
  its certificates are not trusted by browsers but do not count against
  Let's Encrypt production rate limits. Switch the annotation and
  cert-manager re-issues.
- The whole cluster shares one Let's Encrypt account, so its rate limits are
  shared too. Five failed validations per hostname per hour lock that
  hostname out for an hour; fix DNS before retrying.
- HTTP-01 cannot issue wildcard certificates. For a wildcard or a
  certificate from elsewhere, create the TLS Secret yourself, reference it
  from `certificateRefs` and leave the annotation off.

### Rules

- **Never reference the Gateway from a route without `sectionName`.** The
  Gateway's only listener is port 80 and it admits routes from every
  namespace. A route with a hostname and no `sectionName` attaches to it and
  wins over the HTTPS redirect, so your hostname is served in plain text.
- To serve plain HTTP for a hostname on purpose, attach a route to the
  Gateway with `sectionName: http`; that route replaces the redirect for its
  hostname only.
- A listener whose hostname, port and protocol match an existing listener is
  marked `Conflicted` and gets no traffic. Check the status if a new hostname
  does not answer.
- TCP and UDP listeners are allowed (`TCPRoute`, `UDPRoute`). Each new port
  is added to the cluster's load balancer.
- Envoy Gateway policies (`ClientTrafficPolicy`, `SecurityPolicy`,
  `BackendTrafficPolicy`) can target your `ListenerSet` or its listeners.
  Settings that apply to a whole port, such as TLS or connection limits on
  443, affect every listener on that port, including other namespaces'.

## Operating the chart

### Values

| Key | Default | Meaning |
|---|---|---|
| `gateway.loadBalancerIP` | empty | Pre-created floating IP the Envoy Service is pinned to |
| `gateway.serviceAnnotations` | `keep-floatingip: "true"` | Annotations on the Envoy LoadBalancer Service; maps merge with per-cluster values |
| `gateway.allowedListeners.from` | `All` | Namespaces allowed to attach `ListenerSet`s: `None`, `Same`, `All`, `Selector` |
| `gateway.allowedListeners.selector` | `{}` | Namespace label selector when `from` is `Selector` |
| `gateway.replicas`, `gateway.minAvailable` | 2, 1 | Envoy deployment size and disruption budget |
| `letsencrypt.email` | empty | Account email for both issuers (required) |
| `letsencrypt.staging` | `true` | Also render the `letsencrypt-staging` issuer |
| `monitoring.enabled` | `false` | Render the monitors and alert rules |
| `protectedNamespaces` | see `values.yaml` | Namespaces the admission policy keeps customers out of |

`gateway.listeners` was removed in 1.0.0. Hostnames now live in customer
`ListenerSet`s; see "Migrating from chart-managed listeners" below.

### Floating IP

Create the floating IP in the cluster's OpenStack project before the first
sync and put it in `gateway.loadBalancerIP`. cloud-provider-openstack finds
the address and attaches it to the Octavia load balancer it creates for the
Envoy Service. The `keep-floatingip` annotation stops it releasing the
address if the Service is ever deleted, so the IP survives a rebuild of the
data plane. Gateway `spec.addresses` is not used: Envoy Gateway maps it to
Service `externalIPs`, which the OpenStack provider ignores.

### Certificate issuance path

Both ClusterIssuers solve HTTP-01 through `Gateway mks-infra/default`,
listener `http`. cert-manager creates the challenge route in the
certificate's namespace, which is why the `http` listener admits routes from
every namespace. The Gateway keeps its `cert-manager.io/cluster-issuer`
annotation even though it has no TLS listener: cert-manager only reconciles
annotated Gateways, and that reconcile is what deletes Certificates it
created for listeners that no longer exist.

### Monitoring

With `monitoring.enabled`, the chart renders monitors and alert rules for
the managed components. Alerts labelled `owner: mks-admin` route to the MKS
on-call channel through the central Alertmanager; the rest stay with the
cluster's local Alertmanager. The per-certificate alerts carry no owner
because every certificate on a cluster belongs to its users.

### Releasing

1. Bump `version` in `Chart.yaml` and push the change through Gerrit
   (`git commit -s`, `git review`).
2. After it merges, create an annotated tag matching the version on the
   merged commit and push it to both `gerrit` and `origin`. The GitHub
   workflow publishes the chart to `registry.rc.nectar.org.au/nectar-helm`.
3. Renovate proposes the `targetRevision` bump in the Argo CD repositories.

Minor and patch releases are automerged on the test instance; major releases
are not, so breaking changes go out as majors.

## Migrating from chart-managed listeners

Releases before 1.0.0 rendered an HTTPS listener on the Gateway for every
entry in `gateway.listeners`, with the certificate in `mks-infra`. The 1.0.0
bump removes those listeners, so prepare each hostname **before** bumping a
cluster's `targetRevision`. cert-manager must already have ListenerSet
support enabled on that cluster (`config.gatewayAPI.enableListenerSet` and
the `ListenerSets` feature gate).

For each hostname, in the application's namespace:

1. Copy the current certificate so there is no gap. The copy is adopted or
   re-issued once by cert-manager after the cutover; both are seamless.
   ```sh
   kubectl -n mks-infra get secret <hostname>-cert -o json \
     | jq 'del(.metadata.namespace, .metadata.ownerReferences, .metadata.uid,
               .metadata.resourceVersion, .metadata.creationTimestamp,
               .metadata.managedFields, .metadata.annotations, .metadata.labels)
           | .metadata.name = "<hostname>-tls"' \
     | kubectl -n <app-namespace> apply -f -
   ```
2. Create the `ListenerSet` as in "Add a hostname", with `certificateRefs`
   pointing at `<hostname>-tls`. It reports `Accepted=False` with reason
   `NotAllowed` until the chart is bumped. That is expected.
3. Edit the application's `HTTPRoute`: on the existing Gateway `parentRef`
   add `sectionName: <hostname>` (the old listener is named after the
   hostname), and add a second `parentRef` to the `ListenerSet`. The
   `sectionName` matters: after the bump the Gateway's port 80 admits every
   namespace, and a Gateway reference without one would serve the hostname
   in plain text.

Then bump the cluster's `targetRevision` to 1.0.0 and remove `listeners:`
from its values file in the same change. Envoy Gateway programs the
`ListenerSet` listeners in the same update that removes the Gateway ones.
Afterwards:

4. Remove the Gateway `parentRef` from the `HTTPRoute`.
5. Once the new `Certificate` is `Ready`, delete the old Secret from
   `mks-infra` (cert-manager removes the old `Certificate` but never the
   Secret).

Do not edit the Gateway with `kubectl`; Argo CD self-heal reverts it.

## Local rendering

```sh
helm lint . -f test.yaml
helm template . -f test.yaml --namespace mks-infra
```

`test.yaml` holds sample override values for rendering only.
