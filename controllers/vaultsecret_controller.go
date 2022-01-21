/*
Copyright 2022.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controllers

import (
	"context"
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	vaultapi "github.com/hashicorp/vault/api"
	appsv1 "github.com/mink0/vault-operator/api/v1"
	core "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VaultSecretReconciler reconciles a VaultSecret object
type VaultSecretReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

type VaultConfig struct {
	Addr          string
	AuthMethod    string
	AuthPath      string
	Role          string
	Path          string
	SkipVerify    bool
	TLSSecret     string
	ClientTimeout time.Duration
}

const (
	defaultJWTAuthMethod = "jwt"
	defaultJWTFile       = "/var/run/secrets/kubernetes.io/serviceaccount/token"
)

//+kubebuilder:rbac:groups=apps.vault.op,resources=vaultsecrets,verbs=get;list;watch;create;update;patch;delete
//+kubebuilder:rbac:groups=apps.vault.op,resources=vaultsecrets/status,verbs=get;update;patch
//+kubebuilder:rbac:groups=apps.vault.op,resources=vaultsecrets/finalizers,verbs=update

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
// TODO(user): Modify the Reconcile function to compare the state specified by
// the VaultSecret object against the actual cluster state, and then
// perform operations to make the cluster state reflect the state specified by
// the user.
//
// For more details, check Reconcile and its Result here:
// - https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.11.0/pkg/reconcile
func (r *VaultSecretReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	_ = log.FromContext(ctx)

	log.Log.Info("starting vaultSecretReconciler for: '" + req.Name + "'")

	var vaultSecret appsv1.VaultSecret
	if err := r.Get(ctx, req.NamespacedName, &vaultSecret); err != nil {
		log.Log.Error(err, "unable to get vaultSecret resource")
		// we'll ignore not-found errors, since they can't be fixed by an immediate
		// requeue (we'll need to wait for a new notification), and we can get them
		// on deleted requests.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Init Vault config
	config := VaultConfig{}
	config.Addr = vaultSecret.Spec.VaultAddress
	config.Path = vaultSecret.Spec.Path
	config.Role = vaultSecret.Spec.Role
	config.AuthMethod = defaultJWTAuthMethod
	config.AuthPath = "kubernetes"
	if len(vaultSecret.Spec.AuthPath) > 0 {
		config.AuthPath = vaultSecret.Spec.AuthPath
	}

	// Check if the vaultSecret's child Secret already exists, if not create a new one
	found := &core.Secret{}
	err := r.Get(ctx, types.NamespacedName{Name: vaultSecret.Name, Namespace: vaultSecret.Namespace}, found)
	if err != nil && !apierrors.IsNotFound(err) {
		log.Log.Error(err, "unable to get child Secret for the", vaultSecret.Name)
		return ctrl.Result{}, err
	}

	if apierrors.IsNotFound(err) {
		// Fetch the Secret data
		secData, err := r.VaultReadSecret(config)
		if err != nil {
			log.Log.Error(err, "can't read the data from the Vault")
		}

		secret, err := r.SecretMake(&vaultSecret, secData)
		if err != nil {
			log.Log.Error(err, "Failed to generate a Secret resource for the "+secret.Name)
			return ctrl.Result{}, err
		}

		log.Log.Info("deploying a new child Secret: " + secret.Name + " at " + secret.Namespace + " namespace")
		err = r.Client.Create(ctx, secret)
		if err != nil {
			log.Log.Error(err, "failed to deploy a child Secret "+secret.Name+" at "+secret.Namespace+" namespace")
			return ctrl.Result{}, err
		}

		// Child Secret is created successfully, return and requeue
		return ctrl.Result{Requeue: true}, nil
	}

	return ctrl.Result{}, nil
}

// newVaultClient returns initialized Vault client
func (r *VaultSecretReconciler) newVaultClient(vaultConfig VaultConfig) (*vaultapi.Client, error) {
	clientConfig := vaultapi.DefaultConfig()
	if clientConfig.Error != nil {
		return nil, clientConfig.Error
	}

	clientConfig.Address = vaultConfig.Addr

	tlsConfig := vaultapi.TLSConfig{Insecure: vaultConfig.SkipVerify}
	err := clientConfig.ConfigureTLS(&tlsConfig)
	if err != nil {
		return nil, err
	}

	return vaultapi.NewClient(clientConfig)
}

// VaultReadSecret reads secret data from the Vault server
func (r *VaultSecretReconciler) VaultReadSecret(vaultConfig VaultConfig) (*vaultapi.Secret, error) {
	log.Log.Info("fetching Vault secret '" + vaultConfig.Path + "' from the " + vaultConfig.Addr)

	client, err := r.newVaultClient(vaultConfig)
	if err != nil {
		return nil, err
	}

	if vaultConfig.AuthMethod != defaultJWTAuthMethod {
		return nil, errors.New("unsupported Auth method: " + vaultConfig.AuthMethod)
	}

	jwtFile := defaultJWTFile
	if file := os.Getenv("KUBERNETES_SERVICE_ACCOUNT_TOKEN"); file != "" {
		jwtFile = file
	} else if file := os.Getenv("VAULT_JWT_FILE"); file != "" {
		jwtFile = file
	}

	// TODO: SA JWTs do expire, the reading logic should be moved into the loop
	jwt, err := ioutil.ReadFile(jwtFile)
	if err != nil {
		return nil, err
	}

	loginData := map[string]interface{}{
		"jwt":  string(jwt),
		"role": vaultConfig.Role,
	}

	secret, err := client.Logical().Write(fmt.Sprintf("auth/%s/login", vaultConfig.AuthPath), loginData)
	if err != nil {
		log.Log.Error(err, "failed to authenticate")
		return nil, err
	}

	client.SetToken(secret.Auth.ClientToken)
	data, err := client.Logical().Read(vaultConfig.Path)
	if err != nil {
		log.Log.Error(err, "can't read secret '"+vaultConfig.Path+"' from the Vault")
		return nil, err
	}

	return data, nil
}

// SecretMake returns a Secret object with predefined name and values provided
func (r *VaultSecretReconciler) SecretMake(es *appsv1.VaultSecret, secret *vaultapi.Secret) (*core.Secret, error) {
	secObjData := map[string][]byte{}
	if secret != nil {
		for k, v := range secret.Data {
			if k == "data" {
				for kk, vv := range v.(map[string]interface{}) {
					secObjData[kk] = []byte(vv.(string))
				}
			}
		}
	}

	s := &core.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      es.Name,
			Namespace: es.Namespace,
			Annotations: map[string]string{
				es.APIVersion: es.Kind,
			},
		},

		Data: secObjData,
	}

	// establish ownership to make it deleted with the ExtSecret
	ctrl.SetControllerReference(es, s, r.Scheme)
	return s, nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *VaultSecretReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&appsv1.VaultSecret{}).
		Complete(r)
}
