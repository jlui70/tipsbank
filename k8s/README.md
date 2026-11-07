# k8s/ — manifests das etapas 1.4 a 4.4 (registro)

Estes manifests foram aplicados com `kubectl apply` durante as etapas 1.4–4.4 e são referenciados
pelo `docs/EVIDENCIAS.md`. **A partir da etapa 4.5 a fonte da verdade do app é o chart
[`helm/tipsbank`](../helm/tipsbank/)**, publicado em `oci://ghcr.io/jlui70/charts/tipsbank`.

Não aplique estes arquivos num cluster onde o chart está instalado: os objetos teriam dois donos
(Helm e kubectl) e o próximo `helm upgrade` entraria em conflito.
