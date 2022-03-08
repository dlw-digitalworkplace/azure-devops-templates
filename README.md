# Azure Devops Templates

Templates for running CI/CD pipelines in Azure DevOps

# Usage

## Setup

- Add a service connection named `GitHub` to the Azure DevOps project.
- Add a reference to the GitHub repository in your `yaml` file
  ```yaml
  resources:
    repositories:
      - repository: templates
        type: github
        name: dlw-digitalworkplace/azure-devops-templates
        ref: 'refs/heads/main'
        endpoint: GitHub
  ```

## General usage

- Reference the template and pass the necessary parameters.
  ```yaml
  - template: <path_to_template>.yml@templates
    parameters:
      parameter_name: <parameter_value>
      ...
  ```

# Template details

## push/js/push-beachball-package.yml

Pushes updated packages to the specified NPM repository.

### Prerequisites

- [beachball](https://www.npmjs.com/package/beachball) must be added as a (dev)dependency in the project root.
- If pushing to a **private repository**, authentication must be performed before to calling this template.
- Change files should be present in the source.