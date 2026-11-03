import { LightningElement } from 'lwc';
import login from '@salesforce/apex/OrderlyLoginController.login';
import communityBasePath from '@salesforce/community/basePath';

export default class OrderlyLogin extends LightningElement {
    username = '';
    password = '';
    errorMessage = '';
    isLoading = false;

    get forgotPasswordUrl() {
        return `${communityBasePath}/secur/forgotpassword.jsp`;
    }

    handleUsernameChange(event) {
        this.username = event.target.value;
        this.errorMessage = '';
    }

    handlePasswordChange(event) {
        this.password = event.target.value;
        this.errorMessage = '';
    }

    async handleSubmit(event) {
        event.preventDefault();
        if (this.isLoading) return;

        const usernameInput = this.template.querySelector('[data-id="username"]');
        const passwordInput = this.template.querySelector('[data-id="password"]');

        if (!usernameInput.reportValidity() || !passwordInput.reportValidity()) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = '';

        try {
            const destination = await login({
                username: this.username,
                password: this.password,
                startUrl: '/'
            });

            if (destination) {
                window.location.assign(destination);
            } else {
                this.errorMessage = 'Unable to sign in. Please check your credentials and try again.';
            }
        } catch (error) {
            this.errorMessage = error?.body?.message || 'Invalid username or password. Please try again.';
        } finally {
            this.isLoading = false;
        }
    }
}