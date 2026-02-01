import * as cdk from 'aws-cdk-lib';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as ecrAssets from 'aws-cdk-lib/aws-ecr-assets';
import { Construct } from 'constructs';
import * as path from 'path';

export interface ContainerStackProps extends cdk.StackProps {
  ecrRepoName: string;
}

export class ContainerStack extends cdk.Stack {
  public readonly repository: ecr.IRepository;
  public readonly imageUri: string;

  constructor(scope: Construct, id: string, props: ContainerStackProps) {
    super(scope, id, props);

    // Create ECR repository
    this.repository = new ecr.Repository(this, 'Repository', {
      repositoryName: props.ecrRepoName,
      removalPolicy: cdk.RemovalPolicy.RETAIN, // Keep images on stack deletion
      imageScanOnPush: true,
      lifecycleRules: [
        {
          description: 'Keep last 10 images',
          maxImageCount: 10,
        },
      ],
    });

    // Build and push Docker image from Dockerfile
    const dockerImage = new ecrAssets.DockerImageAsset(this, 'DockerImage', {
      directory: path.join(__dirname, '../../container'),
      platform: ecrAssets.Platform.LINUX_AMD64,
    });

    this.imageUri = dockerImage.imageUri;

    new cdk.CfnOutput(this, 'ImageUri', {
      value: this.imageUri,
      description: 'Container image URI',
      exportName: 'AtxContainerImageUri',
    });

    new cdk.CfnOutput(this, 'RepositoryUri', {
      value: this.repository.repositoryUri,
      description: 'ECR repository URI',
      exportName: 'AtxEcrRepositoryUri',
    });

    new cdk.CfnOutput(this, 'RepositoryName', {
      value: this.repository.repositoryName,
      description: 'ECR repository name',
    });
  }
}
