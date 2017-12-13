#!/bin/sh

check_crd() {
	local name=$1
	kubectl get crd $name > /dev/null 2>&1
}

create_crd() {
	local name=$1
	kubectl apply -f $name-crd.yaml
}

check_service() {
	local name=$1
	kubectl get service $name > /dev/null 2>&1
}

create_service() {
	local name=$1

	echo "Create service: $name"
	f=$(mktemp)
	sed \
		-e "s/%%NAME%%/$name/g" \
		svc-tmpl.yaml > $f
	kubectl create -f $f
	rm -f $f
}

check_deployment() {
	local name=$1

	kubectl get deployment $name > /dev/null 2>&1
}

create_deployment() {
	local name=$1
	local db=$2
	local user=$3
	local password=$4

	echo "Create deployment: $name"
	f=$(mktemp)
	sed \
		-e "s/%%NAME%%/$name/g" \
		-e "s/%%DB%%/$db/g" \
		-e "s/%%USER%%/$user/g" \
		-e "s/%%PASSWORD%%/$password/g" \
		deploy-tmpl.yaml > $f
	kubectl create -f $f
	rm -f $f
}

get_pod_name() {
	local name=$1

	for i in $(kubectl get pods --selector "name=$name" -o jsonpath='{.items[*].metadata.name}'); do
		status=$(kubectl get pod $i -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
		if [ "$status" = "True" ]; then
			echo $i
		fi
	done
}

check_pod() {
	local name=$1

	kubectl get pod $name > /dev/null 2>&1
}

check_pod_status_ready() {
	local name=$1

	test "$(kubectl get pod $name -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True"
}

check_pod_app_ready() {
	local pod_name=$1

	test "$(kubectl get pod $pod_name -o jsonpath='{.metadata.labels.appReady}')" = "ok"
}

pod_ip() {
	local pod_name=$1
	kubectl get pod $pod_name -o jsonpath={.status.podIP}
}

app_password() {
	local password=$1
	kubectl get secret $password -o jsonpath='{.data.postgresql_password}' | base64 -d
}

get_pod_app_ready() {
	local pod_name=$1
	local name=$2
	local db=$3
	local user=$4
	local password=$5

	echo "Make the application ready: $pod_name ($name)"
	bk="backup/${name}.sql"
	if [ -f "${bk}" -a -s "${bk}" ]; then
		echo "Restore from backup: $name"
		ip=$(pod_ip $pod_name)
		pw=$(app_password $password)
		env PGPASSWORD=$pw psql -q -h $ip -U$user $db -f "${bk}" && \
		kubectl label --overwrite pod $pod_name appReady=ok
	else
		kubectl label --overwrite pod $pod_name appReady=ok
	fi
}

backup_pod_app() {
	local pod_name=$1
	local name=$2
	local db=$3
	local user=$4
	local password=$5

	echo "Creating backup: $name"
	bk="backup/${name}.sql"
	tmpbk="$(mktemp backup/.${name}-XXXXXX)"
	ip=$(pod_ip $pod_name)
	pw=$(app_password $password)
	env PGPASSWORD=$pw pg_dump -h $ip -U$user $db > "$tmpbk"
	if [ $? -eq 0 ]; then
		mv -f "$tmpbk" "$bk"
	else
		echo "Failed to pg_dump: $name"
	fi
	rm -f "$tmpbk"
}

ensure_service() {
	local name=$1
	local db=$2
	local user=$3
	local password=$4
	local do_backup=$5

	if ! check_service $name; then
		echo "Service not found: $name"
		create_service $name
		return
	fi

	if ! check_deployment $name; then
		echo "Deployment not found: $name"
		create_deployment $name $db $user $password
		return
	fi

	local pod_name=$(get_pod_name $name)

	if [ -z "$pod_name" ]; then
		echo "Pod not ready: $name"
		# deployment will cerate pod for us
		return
	fi

	if ! check_pod_app_ready $pod_name; then
		echo "Application not ready: $pod_name ($name)"
		get_pod_app_ready $pod_name $name $db $user $password
		return
	fi

	if [ $do_backup -eq 0 ]; then
		backup_pod_app  $pod_name $name $db $user $password
	fi
}

crd_name="postgresqls.exp.wheel.jp"
interval=1
backup_interval_factor=5

c=$backup_interval_factor
while :; do
	c=$((c - 1))
	if ! check_crd $crd_name; then
		echo "Create CRD: $crd_name"
		create_crd $crd_name
		sleep 1
		continue
	fi

	for i in $(kubectl get $crd_name -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.end}'); do
		ensure_service $(kubectl get $crd_name $i -o jsonpath='{.metadata.name}{"\t"}{.spec.db}{"\t"}{.spec.user}{"\t"}{.spec.password}{"\n"}') $c
	done

	if [ $c -le 0 ]; then
		c=$backup_interval_factor
	fi

	sleep $interval
done
