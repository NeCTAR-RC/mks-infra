{{/*
HTTP-01 solver shared by the ClusterIssuers. The explicit parentRef is what
places every challenge route, including the ones cert-manager creates for
customer ListenerSets in their own namespaces, on the Gateway's port 80
listener. cert-manager appends the ListenerSet itself as a second parent;
that one never serves the challenge because the ListenerSet has no HTTP
listener, and it is harmless.
*/}}
{{- define "mks-infra.http01Solver" -}}
- http01:
    gatewayHTTPRoute:
      parentRefs:
        - group: gateway.networking.k8s.io
          kind: Gateway
          name: default
          namespace: {{ .Release.Namespace }}
          sectionName: http
{{- end -}}
